# CLI Reference

The `wiggum` command is the primary interface to the harness.

**Working Directory:** All commands can be run from any subdirectory within the project. wiggum automatically finds the project root by walking up the directory tree to find `.wiggum/` or the git repository root.

---

## Command Groups

```
wiggum
├── init / attach / teardown    # Session management
├── spawn / list / kill / ping  # Pane management
├── status / fetch / digest     # Observability
└── ticket                      # Ticket subcommands
```

---

## Session Management

### wiggum init

Initialize a new wiggum project.

```bash
wiggum init
```

**Effects:**
- Creates `.wiggum/` directory structure at the git repository root:
  - `.wiggum/config.sh` — configuration
  - `.wiggum/tickets.git/` — bare git repo for tickets (with pre-receive/post-receive hooks)
  - `.wiggum/tickets/` — clone for CLI access
  - `.wiggum/hooks/` — state transition hooks (copied from defaults)
  - `.wiggum/prompts/` — agent prompt templates (copied from defaults)

**Note:** Does not create a tmux session. The session is created lazily by `wiggum spawn` when first needed. Can be run from any subdirectory within the git repository.

---

### wiggum attach

Attach to an existing wiggum session.

```bash
wiggum attach [--session NAME]
```

---

### wiggum teardown

Tear down the session and cleanup.

```bash
wiggum teardown [--force]
```

**Flags:**
- `--force` — Kill even if workers are active

---

## Pane Management

**Pane identifiers:** Commands that take `<pane-id>` accept either the pane name (e.g., `worker-0`) or the tmux pane index (e.g., `1`). Pane names are preferred as they're stable across layout changes.

### wiggum spawn

Spawn an agent in a new pane. Creates the tmux session if it doesn't exist.

```bash
wiggum spawn <role> [ticket-id] [--prompt PATH]
```

**Arguments:**
- `role` — Agent role name, matches prompt file (e.g., `supervisor`, `worker`, `reviewer`, `qa`)
- `ticket-id` — Ticket to assign (not needed for supervisor)

The role name directly corresponds to the prompt template file: `wiggum spawn foo` loads `.wiggum/prompts/foo.md`.

**Flags:**
- `--prompt PATH` — Override default prompt for this role

**Worktree branching:**

Each agent gets its own git worktree. Workers branch from HEAD (main). Reviewers and QA agents branch from the implementer's branch (looked up via the ticket's `assigned_agent_id`) so they can see the worker's changes. See [architecture.md](./architecture.md#worktree-branching) for details.

**Examples:**

```bash
wiggum spawn supervisor
wiggum spawn worker tk-5c46
wiggum spawn reviewer tk-5c46 --prompt .wiggum/prompts/security-review.md
```

---

### wiggum list

List active panes and their assignments.

```bash
wiggum list [--format FORMAT]
```

**Flags:**
- `--format` — Output format: `table` (default), `json`, `ids`

**Output:**

```
AGENT        ROLE         TICKET       UPTIME
supervisor-0 supervisor   —            2h 15m
worker-0     worker       tk-5c46      1h 30m
worker-1     worker       tk-8a2b      45m
reviewer-0   reviewer     tk-3a1b      10m
```

---

### wiggum kill

Kill a worker pane and clean up its resources.

```bash
wiggum kill <pane-id> [--release-ticket] [--force]
```

**Effects:**
- Kills the tmux pane associated with the agent.
- Attempts to remove the git worktree and delete the agent's branch.
- Unregisters the agent from the pane registry.

**Flags:**
- `--release-ticket` — Return assigned ticket to `ready` state.
- `--force` — Force removal of worktree and branch even if they contain modified or unmerged changes.

---

### wiggum ping

Send a message to a worker pane.

```bash
wiggum ping <pane-id> <message>
```

Sends the message as input to the pane, waking the agent.

**Example:**

```bash
wiggum ping worker-0 "Review comment added to your ticket. Please address."
```

---

## Observability

### wiggum status

Overview of the hive.

```bash
wiggum status [--verbose]
```

**Output:**

```
SESSION: wiggum-myproject (4 panes)

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

### wiggum fetch

Get summarized progress from a worker.

```bash
wiggum fetch <pane-id> [prompt]
```

See [tools.md](./tools.md) for details.

---

### wiggum digest

Summarize the whole hive.

```bash
wiggum digest [prompt]
```

See [tools.md](./tools.md) for details.

---

### wiggum logs

Raw pane output (for debugging).

```bash
wiggum logs <pane-id> [--tail N] [--follow]
```

**Flags:**
- `--tail N` — Show last N lines (default: 50)
- `--follow` — Stream new output

---

## Ticket Subcommands

All ticket operations are under `wiggum ticket`:

```bash
wiggum ticket <subcommand>
```

### Create & Edit

```bash
wiggum ticket create <title> [flags]
    --type TYPE            # feature, bug, task, epic, chore
    --priority N           # 0-4 (0 = highest)
    --dep ID               # Add dependency (repeatable)
    --description, -d TEXT # Set ticket description
    --acceptance-test TEXT # Add acceptance criterion (repeatable)

wiggum ticket edit <id>
    # Opens ticket in $EDITOR
```

### Query

```bash
wiggum ticket list [--state STATE] [--type TYPE]
wiggum ticket show <id>
wiggum ticket ready           # Tickets available for work
wiggum ticket blocked         # Tickets waiting on dependencies
wiggum ticket tree <id>       # Dependency tree
```

### State Transitions

```bash
wiggum ticket transition <id> <state> [--no-sync]
```

Transitions a ticket to a new state. Valid transitions are enforced by the state machine (see [tickets.md](./tickets.md#state-machine)).

**Examples:**

```bash
# Start work on a ticket
wiggum ticket transition tk-5c46 in-progress

# Submit for review
wiggum ticket transition tk-5c46 review

# Skip sync (for manual intervention)
wiggum ticket transition tk-5c46 ready --no-sync
```

### Assignment

```bash
wiggum ticket assign <id> <agent-id>
wiggum ticket unassign <id>
```

**Arguments:**
- `id` — Target ticket
- `agent-id` — Agent to assign (e.g., `worker-0`, `reviewer-1`)

**Examples:**

```bash
# Manually assign an agent to a ticket
wiggum ticket assign tk-5c46 worker-0

# Remove assignment from a ticket
wiggum ticket unassign tk-5c46
```

These commands directly mutate the `assigned_agent_id` and `assigned_at` frontmatter fields. They do not change the ticket state—use `transition` for that. Useful for manual intervention or reassignment scenarios.

### Comment

```bash
wiggum ticket comment <id> <source> <message>
```

**Arguments:**
- `id` — Target ticket
- `source` — Who's leaving the comment (e.g., `reviewer`, `qa`)
- `message` — The comment content

**Example:**

```bash
wiggum ticket comment tk-5c46 reviewer "Missing rate limiting. Add test for expired tokens."
```

Appends comment to the ticket and pings the assigned worker pane if one exists.

### Sync

Ticket operations auto-sync with the bare repo. Manual sync:

```bash
wiggum ticket sync              # Pull + push
wiggum ticket sync --pull       # Pull only
wiggum ticket sync --push       # Push only
```

---

## Hook Subcommands

### wiggum hook run

Run a hook manually.

```bash
wiggum hook run <hook-name> <ticket-id>
```

**Arguments:**
- `hook-name` — Name of the hook (e.g., `on-draft-done`, `on-review-rejected`)
- `ticket-id` — Ticket to pass to the hook

**Example:**

```bash
wiggum hook run on-draft-done tk-5c46
```

Useful for testing hooks or manual intervention.

---

### wiggum hook list

List available hooks.

```bash
wiggum hook list
```

Shows project hooks (`.wiggum/hooks/`) and default hooks, with active/inactive status.

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

These can be set in `.wiggum/config.sh` or exported:

| Variable | Description | Default |
|----------|-------------|---------|
| `WIGGUM_SESSION` | tmux session name | `wiggum-<dirname>` |
| `WIGGUM_MAX_AGENTS` | Max concurrent agent panes (excludes supervisor) | `4` |
| `WIGGUM_POLL_INTERVAL` | Supervisor poll interval (seconds) | `10` |
| `WIGGUM_AGENT_CMD` | Inner harness command | `claude` |
| `WIGGUM_LAYOUT` | tmux pane layout | `tiled` |
| `WIGGUM_EDITOR` | Editor for ticket edit | `$EDITOR` |
| `WIGGUM_AUTO_SYNC` | Auto-sync tickets on read/write | `true` |
| `WIGGUM_EDITOR_MODE` | Input mode for agents (`normal`, `vim`) | `normal` |

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
