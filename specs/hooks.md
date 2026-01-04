# Hooks

Hooks are shell scripts triggered by ticket state transitions. They encode the pipeline logic—when implementation finishes, spawn a reviewer; when review passes, spawn QA; etc.

Hooks are **git-style**, not agent-specific. This keeps wiggum agent-agnostic: any inner harness that can read/write files works.

---

## Location

Hooks live in `.wiggum/hooks/`:

```
.wiggum/hooks/
├── on-claim
├── on-draft-done
├── on-review-done
├── on-review-rejected
├── on-qa-done
├── on-qa-rejected
└── on-close
```

**Note:** There are two hook systems in wiggum:

1. **State transition hooks** (this document) — `.wiggum/hooks/` — your pipeline logic
2. **Git hooks** — `.wiggum/tickets.git/hooks/` — internal plumbing

The git hooks (`pre-receive`, `post-receive`) in the bare ticket repo handle validation and trigger the state transition hooks automatically. You typically only write state transition hooks; the git hooks are installed by `wiggum init`.

See [tickets.md](./tickets.md#sync--distribution) for details on the git hook internals.

---

## Hook Reference

| Hook | Trigger | Typical Use |
|------|---------|-------------|
| `on-claim` | Ticket in-progress by worker | Log, notify, setup |
| `on-draft-done` | Worker finishes implementation | Spawn reviewer |
| `on-review-done` | Reviewer approves | Spawn QA agent |
| `on-review-rejected` | Reviewer rejects | Inject feedback, ping worker |
| `on-qa-done` | QA passes | Close ticket |
| `on-qa-rejected` | QA fails | Inject feedback, reopen for worker |
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
WIGGUM_TICKET_ID     # Same as $1
WIGGUM_TICKET_PATH   # Full path to ticket file
WIGGUM_PREV_STATE    # State before transition
WIGGUM_NEW_STATE     # State after transition
WIGGUM_AGENT_ID      # Agent that triggered transition (if any)
WIGGUM_SESSION       # tmux session name
```

---

## Example Hooks

### on-draft-done

Spawn a review agent when implementation completes:

```bash
#!/bin/bash
# .wiggum/hooks/on-draft-done

TICKET_ID="$1"

echo "[hook] Implementation done for $TICKET_ID, spawning reviewer"
wiggum spawn reviewer "$TICKET_ID"
```

### on-review-rejected

Inject feedback and ping the worker:

```bash
#!/bin/bash
# .wiggum/hooks/on-review-rejected

TICKET_ID="$1"
AGENT_ID="$WIGGUM_AGENT_ID"

echo "[hook] Review rejected for $TICKET_ID"

# Transition back to in-progress
wiggum ticket transition "$TICKET_ID" in-progress

# Ping the original worker (if still running)
if [[ -n "$AGENT_ID" ]]; then
  wiggum ping "$AGENT_ID" "Review feedback added to your ticket. Please address."
fi
```

### on-qa-done

Close the ticket and optionally tag a release:

```bash
#!/bin/bash
# .wiggum/hooks/on-qa-done

TICKET_ID="$1"

echo "[hook] QA passed for $TICKET_ID"

# Close the ticket
wiggum ticket transition "$TICKET_ID" done

# Check if all tickets are done, maybe tag release
if [[ -z "$(wiggum ticket list --state in-progress,review,qa)" ]]; then
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
# .wiggum/hooks/on-close

TICKET_ID="$1"
TICKET_PATH="$WIGGUM_TICKET_PATH"

# Calculate cycle time
CREATED=$(grep 'created_at:' "$TICKET_PATH" | cut -d' ' -f2)
CLOSED=$(date -Iseconds)

echo "[metrics] $TICKET_ID closed. Created: $CREATED, Closed: $CLOSED"

# Could append to a metrics log, send to telemetry, etc.
```

---

## Hook Execution

Hooks are executed by wiggum when state transitions occur:

1. Worker calls `wiggum ticket transition <id> <state>`
2. wiggum validates the transition
3. wiggum updates the ticket file
4. wiggum executes the appropriate hook (if present)
5. Hook runs with full context available
6. Transition completes when hook script exits

### Synchronous Script, Asynchronous Agents

The hook *script* runs synchronously—the transition waits for the script to exit. However, `wiggum spawn` returns immediately after creating the pane. Spawned agents run asynchronously, decoupled from the hook.

```
transition to `qa`
       │
       ▼
┌─────────────────────────┐
│ on-review-done hook     │
│                         │
│  wiggum spawn qa $TK_ID │───▶ (pane created, returns immediately)
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

wiggum ships with sensible default hooks that in-progress the standard pipeline:

```
in-progress → review → qa → done
```

Users can override by placing their own scripts in `.wiggum/hooks/`. The harness checks for user hooks first, falls back to defaults.

---

## Disabling Hooks

Hooks are triggered by the `post-receive` git hook in the bare repo after sync. To skip hooks, use `--no-sync`:

```bash
wiggum ticket transition <id> <state> --no-sync
```

Note: This prevents the state change from syncing to other agents. Useful for manual intervention or recovery scenarios.
