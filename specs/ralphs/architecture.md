# Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        tmux session                             │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │ window: main                                              │  │
│  │  ┌─────────────┬─────────────┬─────────────┬───────────┐  │  │
│  │  │ pane 0      │ pane 1      │ pane 2      │ pane 3    │  │  │
│  │  │ supervisor  │ impl-0      │ impl-1      │ review-0  │  │  │
│  │  │             │ tk-5c46     │ tk-8a2b     │ tk-5c46   │  │  │
│  │  └─────────────┴─────────────┴─────────────┴───────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   .ralphs/tickets/                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ tk-5c46  │  │ tk-8a2b  │  │ tk-9f3c  │  │ tk-epic  │        │
│  │ state:   │  │ state:   │  │ state:   │  │ children:│        │
│  │ review   │  │ implement│  │ ready    │  │ 5c46,... │        │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      .ralphs/hooks/                             │
│  on-claim │ on-implement-done │ on-review-done │ on-close       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| **tmux** | Process isolation, pane lifecycle, attach/detach, log capture |
| **tickets** | Task state, dependencies, unified state machine |
| **hooks** | Trigger pipeline stages on ticket state transitions |
| **tools** | Summarization, feedback injection, context building |
| **prompts** | Role-specific agent instructions |

---

## Directory Structure

```
project/
├── .ralphs/
│   ├── config.sh              # harness configuration
│   │
│   ├── tickets/               # git-backed ticket storage
│   │   ├── tk-5c46.md
│   │   └── tk-8a2b.md
│   │
│   ├── hooks/                 # state transition hooks
│   │   ├── on-claim
│   │   ├── on-implement-done
│   │   ├── on-review-done
│   │   ├── on-review-rejected
│   │   ├── on-qa-done
│   │   └── on-close
│   │
│   └── prompts/               # agent role templates
│       ├── supervisor.md
│       ├── implementer.md
│       ├── reviewer.md
│       └── qa.md
│
├── specs/                     # project specifications
│   └── *.md
│
└── AGENT.md                   # inner harness instructions
```

---

## The Supervisor

The supervisor is a **high-level scheduler**, not a processor.

### Does

- Query ticket state (`ralphs ticket ready`, `ralphs ticket blocked`)
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
  for pane in $(ralphs list); do
    summary=$(ralphs fetch $pane "any blockers?")
    # Decide based on summary, not raw output
  done

  # Spawn new workers for ready tickets
  for ticket in $(ralphs ticket ready --limit 3); do
    if ralphs has-capacity; then
      ralphs spawn impl $ticket
    fi
  done

  sleep $RALPHS_POLL_INTERVAL
done
```

---

## Worker Agents

Workers are **focused executors**. Each worker:

1. Reads its assigned ticket on startup
2. Works on the task described
3. Updates the ticket with progress/notes
4. Signals completion (state transition triggers hooks)
5. Addresses feedback if ticket returns to them

Workers don't know about other workers. They focus on their ticket.

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

`.ralphs/config.sh`:

```bash
# Session name
RALPHS_SESSION="ralphs-myproject"

# Max concurrent worker panes
RALPHS_MAX_WORKERS=4

# Poll interval for supervisor (seconds)
RALPHS_POLL_INTERVAL=10

# Inner harness command
RALPHS_AGENT_CMD="claude"  # or "amp", "aider", etc.

# Pane layout
RALPHS_LAYOUT="tiled"  # or "even-horizontal", "even-vertical"
```
