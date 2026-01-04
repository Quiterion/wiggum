# CLI Reference

The `ralphs` command is the primary interface to the harness.

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

Initialize a new ralphs session.

```bash
ralphs init [--session NAME] [--config PATH]
```

**Flags:**
- `--session NAME` — tmux session name (default: `ralphs-<dirname>`)
- `--config PATH` — Path to config file (default: `.ralphs/config.sh`)

**Effects:**
- Creates `.ralphs/` directory structure if needed
- Starts tmux session
- Sources configuration

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

### ralphs spawn

Spawn an agent in a new pane.

```bash
ralphs spawn <role> <ticket-id> [--prompt PATH]
```

**Arguments:**
- `role` — Agent role: `supervisor`, `impl`, `reviewer`, `qa`
- `ticket-id` — Ticket to assign (not needed for supervisor)

**Flags:**
- `--prompt PATH` — Override default prompt for this role

**Examples:**

```bash
ralphs spawn supervisor
ralphs spawn impl tk-5c46
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
0          supervisor  -          running      2h 15m
1          impl-0      tk-5c46    running      1h 30m
2          impl-1      tk-8a2b    running      45m
3          review-0    tk-3a1b    running      10m
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
ralphs ping impl-0 "Review feedback added to your ticket. Please address."
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

WORKERS:
  impl-0      tk-5c46    implement    1h 30m
  impl-1      tk-8a2b    implement    45m
  review-0    tk-3a1b    review       10m

TICKETS:
  ready:      2
  implement:  2
  review:     1
  qa:         0
  done:       5
  blocked:    1
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

### Sync

Ticket operations auto-sync with the bare repo. Manual sync:

```bash
ralphs ticket sync              # Pull + push
ralphs ticket sync --pull       # Pull only
ralphs ticket sync --push       # Push only
```

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

```bash
RALPHS_SESSION        # tmux session name
RALPHS_MAX_WORKERS    # Max concurrent worker panes
RALPHS_POLL_INTERVAL  # Supervisor poll interval (seconds)
RALPHS_AGENT_CMD      # Inner harness command (claude, amp, etc.)
RALPHS_LAYOUT         # tmux pane layout
RALPHS_EDITOR         # Editor for ticket edit (default: $EDITOR)
```

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
