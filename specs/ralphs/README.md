# ralphs: Multi-Agent Orchestration Harness

**Version:** 0.1.0-draft
**Lineage:** Evolved from [Classic Ralph](../ralph_classic.md)

---

## What is ralphs?

`ralphs` is a minimalist outer harness for orchestrating multiple coding agents. A single ralph is unreliable, but a *school* of ralphs—properly orchestrated—ships production code.

The harness is **thin glue** between:
- **tmux** — process lifecycle and observability
- **tickets** — git-backed task state and dependencies
- **hooks** — pipeline stages triggered by state transitions
- **tools** — summarization so supervisors stay context-light

No daemons. No databases. Just shell scripts, markdown files, and Unix philosophy.

---

## Design Principles

### Inherited from Classic Ralph

1. **File-based state** — Tickets and specs are markdown. Human-readable, git-tracked, agent-accessible.

2. **Deterministic context loading** — Each agent loop loads the same stack: its ticket, relevant specs, role prompt.

3. **One task per agent** — Each agent focuses on exactly one ticket at its abstraction level.

4. **Backpressure through validation** — Code generation is cheap; validation gates progression.

5. **Eventual consistency** — Agents fail. Design for retry, rollback, recovery.

### New in ralphs

6. **Externalized orchestration** — Subagent spawning moves from inside the agent to the harness. Observable, controllable, survivable.

7. **Scope-relative tasks** — "One task" is fractal. Supervisor's task = epic. Worker's task = component. Inner subagents = functions.

8. **Summarization over raw data** — Supervisors invoke tools that return *insights*, not 10k tokens of trajectory logs. (See: [tools.md](./tools.md) for the WebFetch analogy)

9. **Pipeline as hooks** — Backpressure stages (implement → review → QA) encoded as hooks triggered by ticket state transitions.

10. **Agent-agnostic** — Works with any inner harness that can read files, write files, run shell commands.

---

## Quick Start

```bash
# Initialize ralphs in your project
ralphs init

# Create a ticket
ralphs ticket create "Implement auth middleware" --type feature

# Start the supervisor
ralphs spawn supervisor

# Watch the school work
ralphs status

# Attach to observe
ralphs attach
```

---

## Specification Documents

| Document | Description |
|----------|-------------|
| [architecture.md](./architecture.md) | System diagram, component responsibilities |
| [tickets.md](./tickets.md) | Ticket schema, states, lifecycle |
| [hooks.md](./hooks.md) | Hook system, interface, examples |
| [tools.md](./tools.md) | Summarization tools, WebFetch analogy |
| [cli.md](./cli.md) | Command reference |
| [prompts.md](./prompts.md) | Agent role templates |

---

## Comparison with Classic Ralph

| Aspect | Classic Ralph | ralphs |
|--------|---------------|--------|
| Loop | Single bash while loop | Supervisor + worker panes |
| Subagents | Internal (black box) | External (tmux panes) for long work |
| State | fix_plan.md | Integrated ticket system |
| Backpressure | Single agent runs tests | Pipeline stages via hooks |
| Observability | Watch the stream | `ralphs status`, `ralphs fetch` |
| Recovery | git reset --hard | Per-ticket retry, rollback |
