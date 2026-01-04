# Tickets

wiggum includes an integrated ticket system based on [wedow/ticket](https://github.com/wedow/ticket). Tickets are git-backed markdown files with YAML frontmatter.

Tickets are stored in a bare git repository (`.wiggum/tickets.git`) and cloned to each worktree for multi-agent synchronization. See [Sync & Distribution](#sync--distribution) below.

---

## Why Integrated?

Rather than bolting ticket management onto wiggum, we subsume it:

- **Single mental model** — `.wiggum/` is the whole system
- **Unified state machine** — One `state` field, not `status` vs `stage`
- **First-class hooks** — State transitions naturally trigger hooks
- **Cleaner implementation** — No impedance mismatch

The underlying `tk` CLI is vendored and available, but users interact via `wiggum ticket` commands.

---

## State Machine

```
┌─────────────┐    ┌─────────────┐    ┌──────────┐    ┌────────┐
│    ready    │───▶│ in-progress │───▶│  review  │───▶│   qa   │
└─────────────┘    └─────────────┘    └──────────┘    └────────┘
                          ▲               │              │
                          │               │              │
                          └───────────────┴──────────────┘
                                 (feedback)              │
                                                         ▼
                                                    ┌────────┐
                                                    │  done  │
                                                    └────────┘
```

### States

| State | Description | Typical Actor |
|-------|-------------|---------------|
| `ready` | Dependencies met, available for work | — |
| `in-progress` | Worker is actively working on ticket | Worker |
| `review` | Code review in progress | Reviewer agent |
| `qa` | Quality assurance/testing | QA agent |
| `done` | Completed, all validation passed | — |

### Transitions

| From | To | Trigger | Hook |
|------|----|---------|------|
| `ready` | `in-progress` | Worker assigned to ticket | `on-claim` |
| `in-progress` | `review` | Worker marks done | `on-draft-done` |
| `review` | `qa` | Reviewer approves | `on-review-done` |
| `review` | `in-progress` | Reviewer rejects | `on-review-rejected` |
| `qa` | `done` | QA passes | `on-qa-done` → `on-close` |
| `qa` | `in-progress` | QA fails | `on-qa-rejected` |

---

## Ticket Schema

```yaml
---
# Identity
id: tk-5c46
type: feature        # feature | bug | task | epic | chore
priority: 1          # 0 (highest) to 4 (lowest)

# State (unified)
state: in-progress

# Assignment
assigned_agent_id: worker-0
assigned_at: 2025-07-14T10:30:00Z

# Dependencies
depends_on:
  - tk-3a1b
blocks:
  - tk-9f3c

# Metadata
created_at: 2025-07-14T09:00:00Z
created_by: supervisor
---

# Implement auth middleware

## Description

Add JWT-based authentication middleware to the API routes.

## Acceptance Criteria

- [ ] Middleware validates JWT tokens
- [ ] Invalid tokens return 401
- [ ] Token payload available in request context

## Feedback

### From Review (2025-07-14 14:30)

- Missing rate limiting on auth endpoints
- Add test for expired token case

## Notes

Implementation started with src/middleware/auth.ts
```

---

## Dependencies

Tickets can declare dependencies:

```yaml
depends_on:
  - tk-3a1b    # This ticket needs tk-3a1b done first
blocks:
  - tk-9f3c    # tk-9f3c is waiting on this ticket
```

A ticket is `ready` only when all `depends_on` tickets are `done`.

Query blocked/ready tickets:

```bash
wiggum ticket ready      # Show tickets available for work
wiggum ticket blocked    # Show tickets waiting on dependencies
wiggum ticket tree tk-5c46   # Show dependency tree
```

---

## Feedback Injection

When review or QA fails, feedback is appended to the ticket:

```yaml
## Feedback

### From Review (2025-07-14 14:30)

- Missing rate limiting on auth endpoints
- Add test for expired token case
```

The ticket state returns to `in-progress`, and the assigned worker is pinged:

```bash
# Happens automatically via hook
tmux send-keys -t worker-0 "# Review feedback added. Please address and re-submit." Enter
```

The worker's next loop reads the ticket, sees feedback, addresses it.

---

## Ticket CLI

All ticket operations go through `wiggum ticket`:

```bash
# Create
wiggum ticket create "Title" [--type TYPE] [--priority N] [--dep ID]

# Query
wiggum ticket list              # All tickets
wiggum ticket ready             # Ready for work
wiggum ticket blocked           # Blocked by dependencies
wiggum ticket show <id>         # Full ticket details
wiggum ticket tree <id>         # Dependency tree

# State transitions
wiggum ticket transition <id> <state>   # Change ticket state

# Edit
wiggum ticket edit <id>         # Open in $EDITOR
wiggum ticket feedback <id> <source> <message>   # Append feedback

# Sync (for distributed mode)
wiggum ticket sync              # Pull + push
wiggum ticket sync --pull       # Pull only
wiggum ticket sync --push       # Push only

# Partial ID matching
wiggum ticket show 5c4          # Matches tk-5c46

# Assignment
wiggum ticket assign <id> <agent-id>   # Assign agent to ticket
wiggum ticket unassign <id>            # Remove assignment
```

---

## Manual Assignment

The `assign` and `unassign` commands allow manual control over ticket assignment without changing ticket state.

### assign

```bash
wiggum ticket assign <ticket-id> <agent-id>
```

Sets the `assigned_agent_id` and `assigned_at` frontmatter fields. Use this for:

- Reassigning work from one agent to another
- Manual intervention when automatic assignment fails
- Reserving tickets for specific agents

### unassign

```bash
wiggum ticket unassign <ticket-id>
```

Clears the `assigned_agent_id` and `assigned_at` fields. Use this for:

- Releasing a ticket back to the pool
- Cleaning up stale assignments after agent termination
- Manual recovery scenarios

### Difference from `transition`

| Command | State Change | Assignment |
|---------|--------------|------------|
| `transition` | Any valid transition | None |
| `assign` | None | Sets `assigned_agent_id` |
| `unassign` | None | Clears `assigned_agent_id` |

`transition` changes ticket state. `assign`/`unassign` manipulate assignment without affecting state. To start work on a ticket, use both:

```bash
wiggum ticket transition tk-5c46 in-progress
wiggum ticket assign tk-5c46 worker-0
```

---

## File Format

Tickets are markdown with YAML frontmatter. This enables:

- **Human readability** — Edit in any text editor
- **Git tracking** — Full history, diffs, blame
- **Agent accessibility** — Easy to parse and update
- **IDE integration** — Click ticket IDs in commit messages to jump to files

---

## Sync & Distribution

Tickets are stored in a separate git repository for multi-agent synchronization.

### Architecture

```
.wiggum/
├── tickets.git/          ← bare repo (origin)
│   └── hooks/            ← pre-receive, post-receive
└── tickets/              ← clone (for CLI access)

worktrees/
├── worker-0/.wiggum/tickets/    ← clone
└── reviewer-0/.wiggum/tickets/  ← clone
```

All agents (including supervisor) have their own clone. They push/pull to the bare repo.

### Push Flow

```
agent edits ticket → commits → pushes
                                 ↓
                         pre-receive validates state transition
                                 ↓
                         post-receive triggers hooks (spawn reviewer, etc.)
```

### Auto-Sync

Ticket commands auto-sync by default:
- **Read ops** (`show`, `list`, `ready`) — pull first
- **Write ops** (`create`, `transition`, `feedback`) — pull, act, push

Disable with `WIGGUM_AUTO_SYNC=false` or `--no-sync` flag.

### Manual Sync

```bash
wiggum ticket sync              # Pull + push
wiggum ticket sync --pull       # Pull only
wiggum ticket sync --push       # Push only
```

### Conflict Resolution

Most conflicts auto-resolve via rebase (agents edit different tickets). If rebase fails:
1. Worker sees warning: "Ticket sync conflict"
2. Resolve manually: `git -C .wiggum/tickets rebase --continue`

The bare repo uses `*.md merge=union` to append conflicting additions.

### Concurrent Transitions

If two agents try to transition the same ticket:
1. First push succeeds, hooks fire
2. Second push rejected by pre-receive (state already changed)
3. Second agent pulls, sees new state, adjusts
