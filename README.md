# wiggum

A lean multi-agent orchestration harness. Shell scripts instead of Go binaries. Markdown instead of SQLite.

---

## The Landscape

The agent tooling ecosystem has two layers:

| Layer | Heavy | Lean |
|-------|-------|------|
| **Task Tracking** | [Beads](https://github.com/steveyegge/beads) — 130k lines of Go, SQLite cache, background daemon | [Ticket](https://github.com/wedow/ticket) — single bash script, markdown files |
| **Orchestration** | [Gas Town](https://github.com/steveyegge/gastown) — Go binary, 20-30 agents, Mayor/Witness/Polecats roles | **wiggum** — shell scripts, tmux panes, supervisor/worker/reviewer roles |

**wiggum is to Gas Town as Ticket is to Beads.**

Both Ticket and wiggum make the same bet: for most use cases, the complexity isn't worth it. A bash script you can read beats a Go binary you can't.

---

## Why Lean?

Steve Yegge's Gas Town is impressive—orchestrating 20-30 agents, generating 36 PRs in four hours. But it's also:
- 100% vibe coded ("I've never seen the code")
- Under 3 weeks old
- Built on Beads (another layer of complexity)
- Requires Go installation

wiggum takes the opposite approach:

| Gas Town | wiggum |
|----------|--------|
| Go binary | Shell scripts |
| SQLite + JSONL | Markdown + YAML frontmatter |
| Background daemon | No daemons |
| Complex role hierarchy | Three roles: supervisor, worker, reviewer |
| Beads dependency | Self-contained |

The tradeoff is scale. Gas Town handles 30 agents. wiggum targets 3-5. For most projects, that's enough.

---

## Lineage

wiggum descends from [Classic Ralph](https://ghuntley.com/ralph/)—Geoffrey Huntley's technique of running a coding agent in a bash while loop. Ralph proved that a simple loop, properly tuned, can build production software.

wiggum extends Ralph from one agent to many, keeping the same philosophy:
- File-based state (markdown, not databases)
- Deterministic context loading
- One task per agent
- Backpressure through validation

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    wiggum CLI                       │
│         (spawn, kill, status, ticket, ...)          │
└─────────────────────────────────────────────────────┘
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
┌─────────────────────┐   ┌─────────────────────────┐
│   Ticket System     │   │      tmux Session       │
│  (.wiggum/tickets/) │   │                         │
│                     │   │  ┌─────┐ ┌─────┐ ┌────┐ │
│  tk-a1b2.md         │◄──┼──│super│ │work │ │rev │ │
│  tk-c3d4.md         │   │  │visor│ │er-0 │ │iew │ │
│  ...                │   │  └─────┘ └─────┘ └────┘ │
└─────────────────────┘   └─────────────────────────┘
```

Each agent runs in its own tmux pane with:
- Its own git worktree (isolated branch)
- A role prompt (supervisor/worker/reviewer)
- A single assigned ticket

State flows through tickets. Hooks fire on state transitions.

---

## Quick Start

```bash
# Initialize wiggum in your project
wiggum init

# Create a ticket
wiggum ticket create "Implement auth middleware" --type feature

# Start the supervisor
wiggum spawn supervisor

# Watch progress
wiggum status

# Attach to observe
wiggum attach
```

---

## Core Concepts

**Tickets** — Markdown files with YAML frontmatter. States: `open`, `in-progress`, `review`, `done`. Stored in `.wiggum/tickets/`.

**Roles** — Three types of agents:
- **Supervisor** — Decomposes work, assigns tickets, monitors progress
- **Worker** — Implements one ticket at a time
- **Reviewer** — Reviews worker branches, approves or rejects

**Hooks** — Shell scripts triggered by ticket state transitions. Gates progression.

**Worktrees** — Each worker gets an isolated git worktree. No merge conflicts during parallel work.

---

## Specifications

| Document | Description |
|----------|-------------|
| [architecture.md](./specs/architecture.md) | Component responsibilities |
| [tickets.md](./specs/tickets.md) | Ticket schema and lifecycle |
| [hooks.md](./specs/hooks.md) | Hook system |
| [tools.md](./specs/tools.md) | Summarization tools |
| [cli.md](./specs/cli.md) | Command reference |
| [prompts.md](./specs/prompts.md) | Agent role templates |

---

## Comparison

| Aspect | Classic Ralph | wiggum | Gas Town |
|--------|---------------|--------|----------|
| Agents | 1 | 3-5 | 20-30 |
| Language | Bash | Shell | Go |
| Task state | fix_plan.md | Ticket system | Beads |
| Loop | Single while | Supervisor-managed | Mayor-orchestrated |
| Observability | Watch stream | `wiggum status` | `gt status` |
| Installation | None | Clone repo | `go install` |
