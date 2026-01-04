# CLI Reference

The `ralphs` command is the primary interface to the harness.

**Working Directory:** All commands can be run from any subdirectory within the project. ralphs automatically finds the project root by walking up the directory tree to find `.ralphs/` or the git repository root.

---

## Command Groups

```
ralphs
├── init / attach / teardown    # Session management
├── spawn / list / kill / ping  # Pane management
├── status / fetch / digest     # Observability
└── ticket                      # Ticket subcommands
```

---

## Session Management

### ralphs init

Initialize a new ralphs project.

```bash
ralphs init
```

**Effects:**
- Creates `.ralphs/` directory structure at the git repository root:
  - `.ralphs/config.sh` — configuration
  - `.ralphs/tickets.git/` — bare git repo for tickets (with pre-receive/post-receive hooks)
  - `.ralphs/tickets/` — clone for CLI access
  - `.ralphs/hooks/` — state transition hooks (copied from defaults)
  - `.ralphs/prompts/` — agent prompt templates (copied from defaults)

**Note:** Does not create a tmux session. The session is created lazily by `ralphs spawn` when first needed. Can be run from any subdirectory within the git repository.

---

### ralphs attach

Attach to an existing ralphs session.

```bash
ralphs attach [--session NAME]
```

---

### ralphs teardown

Tear down the session and cleanup.

```bash
ralphs teardown [--force]
```

**Flags:**
- `--force` — Kill even if workers are active

---

## Pane Management

**Pane identifiers:** Commands that take `<pane-id>` accept either the pane name (e.g., `worker-0`) or the tmux pane index (e.g., `1`). Pane names are preferred as they're stable across layout changes.

### ralphs spawn

Spawn an agent in a new pane. Creates the tmux session if it doesn't exist.

```bash
ralphs spawn <role> [ticket-id] [--prompt PATH]
```

**Arguments:**
- `role` — Agent role name, matches prompt file (e.g., `supervisor`, `worker`, `reviewer`, `qa`)
- `ticket-id` — Ticket to assign (not needed for supervisor)

The role name directly corresponds to the prompt template file: `ralphs spawn foo` loads `.ralphs/prompts/foo.md`.

**Flags:**
- `--prompt PATH` — Override default prompt for this role

**Examples:**

```bash
ralphs spawn supervisor
ralphs spawn worker tk-5c46
ralphs spawn reviewer tk-5c46 --prompt .ralphs/prompts/security-review.md
```

---

### ralphs list

List active panes and their assignments.

```bash
ralphs list [--format FORMAT]
```

**Flags:**
- `--format` — Output format: `table` (default), `json`, `ids`

**Output:**

```
PANE       ROLE        TICKET     STATE        UPTIME
0          supervisor-0  -          running      2h 15m
1          worker-0    tk-5c46    running      1h 30m
2          worker-1    tk-8a2b    running      45m
3          reviewer-0    tk-3a1b    running      10m
```

---

### ralphs kill

Kill a worker pane.

```bash
ralphs kill <pane-id> [--release-ticket]
```

**Flags:**
- `--release-ticket` — Return assigned ticket to `ready` state

---

### ralphs ping

Send a message to a worker pane.

```bash
ralphs ping <pane-id> <message>
```

Sends the message as input to the pane, waking the agent.

**Example:**

```bash
ralphs ping worker-0 "Review feedback added to your ticket. Please address."
```

---

## Observability

### ralphs status

Overview of the hive.

```bash
ralphs status [--verbose]
```

**Output:**

```
SESSION: ralphs-myproject (4 panes)

AGENTS:
  supervisor-0  -          -              2h 15m
  worker-0      tk-5c46    in-progress    1h 30m
  worker-1      tk-8a2b    in-progress    45m
  reviewer-0    tk-3a1b    review         10m

TICKETS:
  ready:        2 (1 blocked by deps)
  in-progress:  2
  review:       1
  qa:           0
  done:         5
```

---

### ralphs fetch

Get summarized progress from a worker.

```bash
ralphs fetch <pane-id> [prompt]
```

See [tools.md](./tools.md) for details.

---

### ralphs digest

Summarize the whole hive.

```bash
ralphs digest [prompt]
```

See [tools.md](./tools.md) for details.

---

### ralphs context

Build a briefing for a ticket.

```bash
ralphs context <ticket-id> [prompt]
```

See [tools.md](./tools.md) for details.

---

### ralphs logs

Raw pane output (for debugging).

```bash
ralphs logs <pane-id> [--tail N] [--follow]
```

**Flags:**
- `--tail N` — Show last N lines (default: 50)
- `--follow` — Stream new output

---

## Ticket Subcommands

All ticket operations are under `ralphs ticket`:

```bash
ralphs ticket <subcommand>
```

### Create & Edit

```bash
ralphs ticket create <title> [flags]
    --type TYPE         # feature, bug, task, epic, chore
    --priority N        # 0-4 (0 = highest)
    --dep ID            # Add dependency (repeatable)

ralphs ticket edit <id>
    # Opens ticket in $EDITOR
```

### Query

```bash
ralphs ticket list [--state STATE] [--type TYPE]
ralphs ticket show <id>
ralphs ticket ready           # Tickets available to claim
ralphs ticket blocked         # Tickets waiting on dependencies
ralphs ticket tree <id>       # Dependency tree
```

### State Transitions

```bash
ralphs ticket claim <id>
ralphs ticket transition <id> <state> [--no-hooks]
```

### Feedback

```bash
ralphs ticket feedback <id> <source> <message>
```

**Arguments:**
- `id` — Target ticket
- `source` — Who's giving feedback (e.g., `reviewer`, `qa`)
- `message` — The feedback content

**Example:**

```bash
ralphs ticket feedback tk-5c46 reviewer "Missing rate limiting. Add test for expired tokens."
```

Appends feedback to the ticket and pings the assigned worker pane if one exists.

### Sync

Ticket operations auto-sync with the bare repo. Manual sync:

```bash
ralphs ticket sync              # Pull + push
ralphs ticket sync --pull       # Pull only
ralphs ticket sync --push       # Push only
```

---

## Hook Subcommands

### ralphs hook run

Run a hook manually.

```bash
ralphs hook run <hook-name> <ticket-id>
```

**Arguments:**
- `hook-name` — Name of the hook (e.g., `on-in-progress-done`, `on-review-rejected`)
- `ticket-id` — Ticket to pass to the hook

**Example:**

```bash
ralphs hook run on-in-progress-done tk-5c46
```

Useful for testing hooks or manual intervention.

---

### ralphs hook list

List available hooks.

```bash
ralphs hook list
```

Shows project hooks (`.ralphs/hooks/`) and default hooks, with active/inactive status.

---

## Global Flags

These work with any command:

```bash
--session NAME    # Specify tmux session
--config PATH     # Specify config file
--quiet           # Suppress non-essential output
--verbose         # Extra output for debugging
--help            # Show help for command
```

---

## Configuration via Environment

These can be set in `.ralphs/config.sh` or exported:

| Variable | Description | Default |
|----------|-------------|---------|
| `RALPHS_SESSION` | tmux session name | `ralphs-<dirname>` |
| `RALPHS_MAX_AGENTS` | Max concurrent agent panes (excludes supervisor) | `4` |
| `RALPHS_POLL_INTERVAL` | Supervisor poll interval (seconds) | `10` |
| `RALPHS_AGENT_CMD` | Inner harness command | `claude` |
| `RALPHS_LAYOUT` | tmux pane layout | `tiled` |
| `RALPHS_EDITOR` | Editor for ticket edit | `$EDITOR` |
| `RALPHS_AUTO_SYNC` | Auto-sync tickets on read/write | `true` |
| `RALPHS_EDITOR_MODE` | Input mode for agents (`normal`, `vim`) | `normal` |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 3 | Session not found |
| 4 | Pane not found |
| 5 | Ticket not found |
| 6 | Invalid state transition |
