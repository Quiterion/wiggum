# Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        tmux session                             │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ window: main                                              │  │
│  │  ┌─────────────┬─────────────┬─────────────┬───────────┐  │  │
│  │  │ pane 0      │ pane 1      │ pane 2      │ pane 3    │  │  │
│  │  │ supervisor-0│ worker-0    │ worker-1    │ reviewer-0│  │  │
│  │  │             │ tk-5c46     │ tk-8a2b     │ tk-5c46   │  │  │
│  │  └─────────────┴─────────────┴─────────────┴───────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   .wiggum/tickets/                          │
│  ┌──────────┐  ┌───────────┐  ┌──────────┐  ┌──────────┐    │
│  │ tk-5c46  │  │ tk-8a2b   │  │ tk-9f3c  │  │ tk-epic  │    │
│  │ state:   │  │ state:    │  │ state:   │  │ children:│    │
│  │ review   │  │in-progress│  │ ready    │  │ tk-2e... │    │
│  └──────────┘  └───────────┘  └──────────┘  └──────────┘    │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      .wiggum/hooks/                                 │
│  on-claim │ on-draft-done │ on-review-done │ on-qa-done │ on-close  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| **tmux** | Process isolation, pane lifecycle, attach/detach, log capture |
| **tickets** | Task state, dependencies, unified state machine |
| **hooks** | Trigger pipeline stages on ticket state transitions |
| **tools** | Summarization, comment injection |
| **prompts** | Role-specific agent instructions |

---

## Directory Structure

```
project/                               # main project (human's workspace)
├── .wiggum/
│   ├── config.sh                      # harness configuration
│   ├── tickets.git/                   # bare repo (ticket origin)
│   │   └── hooks/                     # pre-receive, post-receive
│   ├── tickets/                       # clone (for CLI commands from main project)
│   │   ├── tk-5c46.md
│   │   └── tk-8a2b.md
│   ├── hooks/                         # state transition hooks
│   │   ├── on-claim
│   │   ├── on-draft-done
│   │   ├── on-review-done
│   │   ├── on-review-rejected
│   │   ├── on-qa-done
│   │   └── on-close
│   └── prompts/                       # agent role templates
│       ├── supervisor.md
│       ├── worker.md
│       ├── reviewer.md
│       └── qa.md
├── worktrees/                         # agent worktrees
│   ├── supervisor-0/                  # supervisor's worktree
│   │   └── .wiggum/tickets/           # clone
│   └── worker-0/
│       └── .wiggum/tickets/           # clone
├── specs/                             # project specifications
└── AGENT.md                           # inner harness instructions
```

Each agent works in its own git worktree with a cloned tickets repo. The main project also has a clone for running CLI commands. See [tickets.md](./tickets.md#sync--distribution) for synchronization details.

---

## The Supervisor

The supervisor is a **high-level scheduler**, not a processor.

### Does

- Query ticket state (`wiggum ticket ready`, `wiggum ticket blocked`)
- Spawn workers into panes
- Invoke tools to get summarized progress
- Make decisions: retry, escalate, continue, intervene

### Does Not

- Read raw agent trajectories
- Parse build logs directly
- Make low-level engineering decisions

### Conceptual Loop

```bash
while :; do
  # Check worker status via summarization tools
  for pane in $(wiggum list); do
    summary=$(wiggum fetch $pane "any blockers?")
    # Decide based on summary, not raw output
  done

  # Spawn new workers for ready tickets
  for ticket in $(wiggum ticket ready --limit 3); do
    if wiggum has-capacity; then
      wiggum spawn worker $ticket
    fi
  done

  sleep $WIGGUM_POLL_INTERVAL
done
```

---

## Worker Agents

Workers are **focused executors**. Each worker:

1. Reads its assigned ticket on startup
2. Works on the task described
3. Updates the ticket with progress/notes
4. Signals completion (state transition triggers hooks)
5. Addresses comment if ticket returns to them

Workers don't know about other workers. They focus on their ticket.

---

## Worktree Branching

Each agent gets its own git worktree. wiggum uses a **feature-branch-per-ticket** model for organized branch management.

### Branch Structure

| Branch Type | Format | Purpose |
|-------------|--------|---------|
| Feature branch | `feature/tk-xxxx` | Accumulates all work for a ticket |
| Worker branch | `worker-0`, `worker-1` | Individual worker's changes |
| Reviewer branch | `reviewer-0` | Reviewer's working copy |
| QA branch | `qa-0` | QA's working copy |

### Branch Flow

| Role | Branches From | Merges To | Why |
|------|---------------|-----------|-----|
| `supervisor` | HEAD (main) | — | Orchestrates, doesn't need code changes |
| `worker` | `feature/tk-xxxx` | `feature/tk-xxxx` | Works on ticket feature branch |
| `reviewer` | Worker's branch | — | Sees worker's changes |
| `qa` | Worker's branch | — | Sees worker's changes |

### Lifecycle

1. **Worker spawns**: Creates `feature/tk-xxxx` if it doesn't exist, branches from it
2. **Worker submits for review**: Worker branch merges to `feature/tk-xxxx`
3. **Review passes**: Reviewer branch is auto-deleted
4. **QA passes**: QA branch is auto-deleted
5. **Ticket done**: `feature/tk-xxxx` can be merged to main via `wiggum branch merge`

```
main ─────────────────────────────────────────────────
       \
        feature/tk-xxxx ← feature branch (created on first worker spawn)
              \
               worker-0 ← worker branches from feature
                     \
                      (merges back to feature/tk-xxxx on review)
                            \
                             reviewer-0 ← branches from worker
                                   \
                                    (deleted after review passes)
                                          \
                                           qa-0 ← branches from worker
                                                 \
                                                  (deleted after QA passes)
```

### Merge Conflict Handling

When transitioning to `review`, the worker's changes are merged to the feature branch. If conflicts occur:

1. Transition is blocked with exit code 7 (`EXIT_MERGE_CONFLICT`)
2. Error message shows resolution steps
3. Use `wiggum rebase` to help resolve conflicts
4. Retry the transition after resolution

### Branch Commands

```bash
# List all branches, grouped by ticket
wiggum branch list [ticket-id]

# Clean up all branches for a completed ticket
wiggum branch cleanup <ticket-id>

# Merge feature branch to main when ticket is done
wiggum branch merge <ticket-id>

# Rebase current branch on feature branch (conflict resolution)
wiggum rebase [ticket-id]
```

### Viewing Changes

To see what the implementer changed:

```bash
git diff main..HEAD
git log main..HEAD --oneline
```

To see what's on the feature branch:

```bash
git diff main..feature/tk-xxxx
git log main..feature/tk-xxxx --oneline
```

---

## Observable vs Ephemeral Agents

Not every agent invocation needs a tmux pane.

| Pane (observable) | Black box (ephemeral) |
|-------------------|----------------------|
| Long-running work | Quick summarization |
| Needs human oversight | Fire-and-forget |
| Produces artifacts | Returns insight |
| Workers, reviewers, QA | Tool internals |

The [tools](./tools.md) invoke ephemeral agents internally—like how `WebFetch` uses an LLM to summarize web content without exposing that as a separate pane.

---

## Configuration

`.wiggum/config.sh`:

```bash
# Session name
WIGGUM_SESSION="wiggum-myproject"

# Max concurrent agent panes (excludes supervisor)
WIGGUM_MAX_AGENTS=4

# Poll interval for supervisor (seconds)
WIGGUM_POLL_INTERVAL=10

# Inner harness command
WIGGUM_AGENT_CMD="claude"  # or "amp", "aider", etc.

# Pane layout
WIGGUM_LAYOUT="tiled"  # or "even-horizontal", "even-vertical"
```
