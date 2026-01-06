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

**Note:** State transition hooks are invoked directly by `ticket_transition()` after sync operations complete. There are no git hooks in the bare ticket repo—all validation and hook invocation is handled by the ticket data layer.

---

## Hook Reference

| Hook | Trigger | Typical Use |
|------|---------|-------------|
| `on-claim` | Ticket in-progress by worker | Log, notify, setup |
| `on-draft-done` | Worker finishes implementation | Spawn reviewer |
| `on-review-done` | Reviewer approves | Spawn QA agent |
| `on-review-rejected` | Reviewer rejects | Ping worker |
| `on-qa-done` | QA passes | Pings supervisor (todo) |
| `on-qa-rejected` | QA fails | Ping worker |
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

Ping the worker:

```bash
#!/bin/bash
# .wiggum/hooks/on-review-rejected

TICKET_ID="$1"
AGENT_ID="$WIGGUM_AGENT_ID"

echo "[hook] Review rejected for $TICKET_ID"

# Ping the original worker (if still running)
if [[ -n "$AGENT_ID" ]]; then
  wiggum ping "$AGENT_ID" "Review comment added to your ticket. Please address."
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

Hooks are executed directly by `ticket_transition()` during state transitions:

1. Worker calls `wiggum ticket transition <id> <state>`
2. CRUD layer pulls latest state from origin
3. wiggum validates the transition using ticket_types.json
4. **Pre-transition hooks** run (synchronous, can block transition)
5. wiggum updates the ticket file locally
6. CRUD layer pushes changes to origin
7. **Post-transition hooks** run (asynchronous, background)

### Pre-Transition Hooks

Pre-hooks run **before** the state change is committed. They can:
- Validate preconditions (e.g., all tests pass)
- Block the transition by returning non-zero exit code
- Run in the worktree context with full access to code

### Post-Transition Hooks

Post-hooks run **after** the state change is pushed. They:
- Run asynchronously (don't block the caller)
- Typically spawn new agents or send notifications
- Cannot undo the transition

### Synchronous Script, Asynchronous Agents

Post-hook *scripts* run in the background. `wiggum spawn` returns immediately after creating the pane. Spawned agents run asynchronously, decoupled from the hook.

```
transition to `qa`
       │
       ▼
[pre-hooks run, can block]
       │
       ▼
[state updated, pushed]
       │
       ▼
┌─────────────────────────┐
│ on-review-done hook     │ (runs in background)
│                         │
│  wiggum spawn qa $TK_ID │───▶ (pane created, returns immediately)
│  exit 0                 │              │
└─────────────────────────┘              │
       │                                 ▼
       ▼                          QA agent runs
transition returns to caller      (decoupled)
```

This means:
- Pre-hooks can enforce preconditions
- Post-hooks complete quickly (spawn + exit)
- Agents run independently in their panes
- Caller doesn't wait for post-hooks to complete

---

## Default Hooks

wiggum ships with sensible default hooks that in-progress the standard pipeline:

```
in-progress → review → qa → done
```

Users can override by placing their own scripts in `.wiggum/hooks/`. The harness checks for user hooks first, falls back to defaults.

---

## Disabling Hooks

To perform a state transition without triggering hooks, use `--no-hooks`:

```bash
wiggum ticket transition <id> <state> --no-hooks
```

Note: Sync always happens (pull before read, push after write). Only hook execution is skipped. Useful for manual intervention or recovery scenarios where you don't want to spawn agents.
