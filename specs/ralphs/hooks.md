# Hooks

Hooks are shell scripts triggered by ticket state transitions. They encode the pipeline logic—when implementation finishes, spawn a reviewer; when review passes, spawn QA; etc.

Hooks are **git-style**, not agent-specific. This keeps ralphs agent-agnostic: any inner harness that can read/write files works.

---

## Location

Hooks live in `.ralphs/hooks/`:

```
.ralphs/hooks/
├── on-claim
├── on-implement-done
├── on-review-done
├── on-review-rejected
├── on-qa-done
├── on-qa-rejected
└── on-close
```

---

## Hook Reference

| Hook | Trigger | Typical Use |
|------|---------|-------------|
| `on-claim` | Ticket claimed by worker | Log, notify, setup |
| `on-implement-done` | Worker finishes implementation | Spawn reviewer |
| `on-review-done` | Reviewer approves | Spawn QA agent |
| `on-review-rejected` | Reviewer rejects | Inject feedback, ping implementer |
| `on-qa-done` | QA passes | Close ticket |
| `on-qa-rejected` | QA fails | Inject feedback, reopen for implementer |
| `on-close` | Ticket closed | Cleanup, metrics, maybe tag release |

---

## Hook Interface

Hooks receive context via arguments and environment variables:

### Arguments

```bash
$1 = ticket ID
```

### Environment Variables

```bash
RALPHS_TICKET_ID     # Same as $1
RALPHS_TICKET_PATH   # Full path to ticket file
RALPHS_PREV_STATE    # State before transition
RALPHS_NEW_STATE     # State after transition
RALPHS_PANE          # Pane that triggered transition (if any)
RALPHS_SESSION       # tmux session name
```

---

## Example Hooks

### on-implement-done

Spawn a review agent when implementation completes:

```bash
#!/bin/bash
# .ralphs/hooks/on-implement-done

TICKET_ID="$1"

echo "[hook] Implementation done for $TICKET_ID, spawning reviewer"
ralphs spawn reviewer "$TICKET_ID"
```

### on-review-rejected

Inject feedback and ping the implementer:

```bash
#!/bin/bash
# .ralphs/hooks/on-review-rejected

TICKET_ID="$1"
IMPL_PANE="$RALPHS_PANE"

echo "[hook] Review rejected for $TICKET_ID"

# Transition back to implement
ralphs ticket transition "$TICKET_ID" implement

# Ping the original implementer (if still running)
if [[ -n "$IMPL_PANE" ]]; then
  ralphs ping "$IMPL_PANE" "Review feedback added to your ticket. Please address."
fi
```

### on-qa-done

Close the ticket and optionally tag a release:

```bash
#!/bin/bash
# .ralphs/hooks/on-qa-done

TICKET_ID="$1"

echo "[hook] QA passed for $TICKET_ID"

# Close the ticket
ralphs ticket transition "$TICKET_ID" done

# Check if all tickets are done, maybe tag release
if [[ -z "$(ralphs ticket list --state implement,review,qa)" ]]; then
  echo "[hook] All tickets complete, tagging release"
  # Increment patch version
  LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
  NEXT_TAG=$(echo "$LAST_TAG" | awk -F. '{print $1"."$2"."$3+1}')
  git tag "$NEXT_TAG"
fi
```

### on-close

Log metrics and cleanup:

```bash
#!/bin/bash
# .ralphs/hooks/on-close

TICKET_ID="$1"
TICKET_PATH="$RALPHS_TICKET_PATH"

# Calculate cycle time
CREATED=$(grep 'created_at:' "$TICKET_PATH" | cut -d' ' -f2)
CLOSED=$(date -Iseconds)

echo "[metrics] $TICKET_ID closed. Created: $CREATED, Closed: $CLOSED"

# Could append to a metrics log, send to telemetry, etc.
```

---

## Hook Execution

Hooks are executed by ralphs when state transitions occur:

1. Worker calls `ralphs ticket transition <id> <state>`
2. ralphs validates the transition
3. ralphs updates the ticket file
4. ralphs executes the appropriate hook (if present)
5. Hook runs with full context available
6. Transition completes when hook script exits

### Synchronous Script, Asynchronous Agents

The hook *script* runs synchronously—the transition waits for the script to exit. However, `ralphs spawn` returns immediately after creating the pane. Spawned agents run asynchronously, decoupled from the hook.

```
transition to `qa`
       │
       ▼
┌─────────────────────────┐
│ on-review-done hook     │
│                         │
│  ralphs spawn qa $TK_ID │───▶ (pane created, returns immediately)
│  echo "spawned"         │              │
│  exit 0                 │              │
└─────────────────────────┘              │
       │                                 ▼
       ▼                          QA agent runs
transition completes              (decoupled)
```

This means:
- Hooks complete quickly (spawn + exit)
- Agents run independently in their panes
- No blocking on long-running agent work

---

## Default Hooks

ralphs ships with sensible default hooks that implement the standard pipeline:

```
implement → review → qa → done
```

Users can override by placing their own scripts in `.ralphs/hooks/`. The harness checks for user hooks first, falls back to defaults.

---

## Disabling Hooks

To skip hooks for a transition:

```bash
ralphs ticket transition <id> <state> --no-hooks
```

Useful for manual intervention or recovery scenarios.
