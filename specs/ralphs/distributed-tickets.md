# Distributed Tickets

This document specifies the distributed ticket system for multi-agent parallel development.

## Overview

When multiple agents work in parallel (each in their own git worktree), they need a synchronized view of ticket state. This spec describes how tickets are stored in a separate git repository and synchronized across worktrees using git's native mechanisms.

## Architecture

```
proj/                                  ← supervisor lives here (main project worktree)
├── .ralphs/
│   ├── tickets/                       ← git repo, IS the origin
│   │   ├── .git/
│   │   │   ├── config                 ← receive.denyCurrentBranch=updateInstead
│   │   │   └── hooks/
│   │   │       ├── pre-receive        ← validates state transitions
│   │   │       └── post-receive       ← triggers ralphs hooks
│   │   └── *.md                       ← ticket files
│   ├── config.sh
│   ├── hooks/
│   └── prompts/
├── .gitignore                         ← includes .ralphs/tickets/
├── src/...
└── worktrees/
    ├── impl-0/
    │   └── .ralphs/
    │       └── tickets/               ← clone, remote=../../.ralphs/tickets
    └── reviewer-0/
        └── .ralphs/
            └── tickets/               ← clone, remote=../../.ralphs/tickets
```

### Key Principles

1. **Tickets repo is separate from project repo** - ticket churn doesn't pollute project history
2. **Supervisor's tickets IS the origin** - not a bare repo, just a regular repo with special config
3. **Workers clone and push directly** - no intermediate branches, no supervisor merge step
4. **Hooks fire on origin** - pre-receive validates, post-receive triggers actions
5. **Nested repo, not submodule** - simpler setup, tracked via `.gitignore`

## How It Works

### Push to non-bare repo

Normally git refuses to push to a checked-out branch. We use `receive.denyCurrentBranch=updateInstead` which:
- Accepts the push
- Automatically updates the working tree
- Keeps supervisor's view always current

### Worker push flow

```
impl-0: edits ticket, commits, pushes to origin (supervisor's repo)
            ↓
    pre-receive: validates state transition
            ↓
    push accepted, supervisor's working tree updates
            ↓
    post-receive: triggers ralphs hooks (spawn reviewer, etc.)
```

## Initialization

### First-time init (creates supervisor environment)

```bash
ralphs init [--session NAME]
```

1. Create tickets repo at `.ralphs/tickets/`:
   ```bash
   git init .ralphs/tickets
   git -C .ralphs/tickets config receive.denyCurrentBranch updateInstead
   ```
2. Install pre-receive and post-receive hooks
3. Create initial commit (empty README or .gitkeep)
4. Add `.ralphs/tickets/` to project's `.gitignore`
5. Mark this as supervisor: `RALPHS_IS_SUPERVISOR=true` in config
6. Create tmux session, etc. (existing behavior)

### Spawning workers (creates worktree + tickets clone)

```bash
ralphs spawn <role> [--ticket ID]
```

1. Create project worktree:
   ```bash
   git worktree add worktrees/<pane-name> -b <pane-name>
   ```
2. Create worker's .ralphs directory structure
3. Clone tickets repo into worktree:
   ```bash
   git clone ../../.ralphs/tickets worktrees/<pane-name>/.ralphs/tickets
   ```
4. Mark as worker: `RALPHS_IS_SUPERVISOR=false` in worktree's config
5. Register pane, start agent, etc. (existing behavior)

## Synchronization

### Worker → Origin (push)

Workers commit and push directly to main:

```bash
# In worker's .ralphs/tickets/
git add -A
git commit -m "Transition tk-1234: implement → review"
git push origin main
```

- pre-receive validates the state transition
- If invalid, push is rejected with helpful error
- If valid, supervisor's working tree auto-updates
- post-receive triggers appropriate hooks

### Worker ← Origin (pull)

Workers pull before operations:

```bash
# In worker's .ralphs/tickets/
git pull --rebase origin main
```

## Ticket Commands with Git Plumbing

### Sync helpers

```bash
ticket_sync_pull() {
    [[ "$RALPHS_AUTO_SYNC" == "false" ]] && return 0
    git -C "$TICKETS_DIR" fetch origin --quiet
    git -C "$TICKETS_DIR" rebase origin/main --quiet 2>/dev/null || {
        warn "Ticket sync conflict - please resolve manually"
        return 1
    }
}

ticket_sync_push() {
    [[ "$RALPHS_AUTO_SYNC" == "false" ]] && return 0
    local message="$1"
    git -C "$TICKETS_DIR" add -A
    git -C "$TICKETS_DIR" commit -m "$message" --quiet 2>/dev/null || true
    git -C "$TICKETS_DIR" push origin main --quiet
}
```

### Read operations (pull first)

```bash
ticket_show() {
    ticket_sync_pull
    # ... existing show logic ...
}

ticket_list() {
    ticket_sync_pull
    # ... existing list logic ...
}
```

### Write operations (pull, modify, push)

```bash
ticket_transition() {
    ticket_sync_pull

    # Validate and update state
    # ... existing transition logic ...

    ticket_sync_push "Transition $id: $old_state → $new_state"
}

ticket_create() {
    ticket_sync_pull

    # Create ticket file
    # ... existing create logic ...

    ticket_sync_push "Create ticket: $id"
}
```

## Supervisor Detection

```bash
is_supervisor() {
    load_config
    [[ "${RALPHS_IS_SUPERVISOR:-false}" == "true" ]]
}
```

Supervisor detection is also implicit: if there's no remote configured, you're the origin.

```bash
is_origin() {
    local remote
    remote=$(git -C "$TICKETS_DIR" remote get-url origin 2>/dev/null)
    [[ -z "$remote" ]]
}
```

## Origin Hooks

### pre-receive (validation)

Location: `.ralphs/tickets/.git/hooks/pre-receive`

```bash
#!/bin/bash
set -e

# State transition rules
declare -A TRANSITIONS=(
    ["ready"]="claimed"
    ["claimed"]="implement"
    ["implement"]="review"
    ["review"]="qa implement"
    ["qa"]="done implement"
)

validate_transition() {
    local from="$1" to="$2"
    [[ " ${TRANSITIONS[$from]} " == *" $to "* ]]
}

while read oldrev newrev refname; do
    # Skip branch deletion
    [[ "$newrev" == "0000000000000000000000000000000000000000" ]] && continue

    # Check each changed ticket file
    for file in $(git diff --name-only "$oldrev" "$newrev" 2>/dev/null || git ls-tree -r --name-only "$newrev"); do
        [[ "$file" == *.md ]] || continue

        # Get old and new state
        old_state=""
        if [[ "$oldrev" != "0000000000000000000000000000000000000000" ]]; then
            old_state=$(git show "$oldrev:$file" 2>/dev/null | awk '/^state:/{print $2}')
        fi
        new_state=$(git show "$newrev:$file" | awk '/^state:/{print $2}')

        # Skip if state unchanged (body-only edit)
        [[ "$old_state" == "$new_state" ]] && continue

        # New tickets start at ready
        if [[ -z "$old_state" ]]; then
            if [[ "$new_state" != "ready" ]]; then
                echo "error: new tickets must start in 'ready' state, got '$new_state'"
                echo "hint: file: $file"
                exit 1
            fi
            continue
        fi

        # Validate transition
        if ! validate_transition "$old_state" "$new_state"; then
            echo "error: invalid transition '$old_state' → '$new_state'"
            echo "hint: file: $file"
            echo "hint: allowed from '$old_state': ${TRANSITIONS[$old_state]}"
            echo "hint: use 'ralphs ticket transition <id> <state>'"
            exit 1
        fi
    done
done

exit 0
```

### post-receive (hooks trigger)

Location: `.ralphs/tickets/.git/hooks/post-receive`

```bash
#!/bin/bash

# Find project root (.git/hooks -> .git -> tickets -> .ralphs -> proj)
TICKETS_GIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TICKETS_DIR="$(dirname "$TICKETS_GIT_DIR")"
RALPHS_DIR="$(dirname "$TICKETS_DIR")"
PROJECT_ROOT="$(dirname "$RALPHS_DIR")"

# Source ralphs if available
if [[ -f "$RALPHS_DIR/config.sh" ]]; then
    source "$RALPHS_DIR/config.sh"
fi

# Find ralphs installation
RALPHS_BIN=$(command -v ralphs 2>/dev/null || echo "$PROJECT_ROOT/bin/ralphs")

while read oldrev newrev refname; do
    # Skip deletions
    [[ "$newrev" == "0000000000000000000000000000000000000000" ]] && continue

    # Check each changed ticket
    for file in $(git diff --name-only "$oldrev" "$newrev" 2>/dev/null); do
        [[ "$file" == *.md ]] || continue

        ticket_id=$(basename "$file" .md)
        old_state=$(git show "$oldrev:$file" 2>/dev/null | awk '/^state:/{print $2}')
        new_state=$(git show "$newrev:$file" | awk '/^state:/{print $2}')

        [[ "$old_state" == "$new_state" ]] && continue

        # Trigger appropriate hook via ralphs
        case "$new_state" in
            review)
                "$RALPHS_BIN" hook run on-implement-done "$ticket_id" 2>/dev/null || true
                ;;
            qa)
                "$RALPHS_BIN" hook run on-review-done "$ticket_id" 2>/dev/null || true
                ;;
            implement)
                if [[ "$old_state" == "review" ]]; then
                    "$RALPHS_BIN" hook run on-review-rejected "$ticket_id" 2>/dev/null || true
                elif [[ "$old_state" == "qa" ]]; then
                    "$RALPHS_BIN" hook run on-qa-rejected "$ticket_id" 2>/dev/null || true
                fi
                ;;
            done)
                "$RALPHS_BIN" hook run on-qa-done "$ticket_id" 2>/dev/null || true
                "$RALPHS_BIN" hook run on-close "$ticket_id" 2>/dev/null || true
                ;;
        esac
    done
done
```

## Conflict Resolution

### Automatic (rebase)

Most conflicts resolve automatically with rebase since:
- Each worker typically edits different tickets (claimed/assigned to them)
- Body edits are append-mostly (feedback, notes accumulate)

### Manual escalation

If rebase fails:
1. Worker's sync command warns: "Ticket sync conflict"
2. Worker can manually resolve: `git -C .ralphs/tickets rebase --continue`
3. Or abort and escalate to supervisor

### Merge strategy for body content

Configure tickets repo to use union merge for markdown:
```bash
# .ralphs/tickets/.git/info/attributes
*.md merge=union
```

This appends conflicting additions rather than creating conflict markers.

## CLI Changes

### New commands

```bash
ralphs ticket sync              # Manual sync (pull + push)
ralphs ticket sync --pull       # Pull only
ralphs ticket sync --push       # Push only
```

### Modified commands

All ticket commands gain implicit sync:
- Read ops (`show`, `list`, `ready`, `blocked`) → pull first
- Write ops (`create`, `transition`, `claim`, `feedback`) → pull, act, push

### Flags

```bash
--no-sync                       # Skip git sync (for offline/testing)
```

## Configuration

New config options in `.ralphs/config.sh`:

```bash
RALPHS_IS_SUPERVISOR=true|false     # Is this the supervisor worktree?
RALPHS_AUTO_SYNC=true|false         # Auto-sync on ticket operations (default: true)
```

## Migration

For existing ralphs projects without distributed tickets:

```bash
ralphs migrate-tickets
```

1. Initializes git in existing `.ralphs/tickets/` directory
2. Configures `receive.denyCurrentBranch=updateInstead`
3. Installs hooks
4. Creates initial commit

## Edge Cases

### Offline operation

With `RALPHS_AUTO_SYNC=false` or `--no-sync`:
- Operations work locally
- User must manually sync when online: `ralphs ticket sync`

### Concurrent transitions

If two workers try to transition the same ticket:
1. First push succeeds, hooks fire
2. Second push fails pre-receive validation (state already changed)
3. Second worker sees error, pulls to get new state, adjusts

### Supervisor operations

Supervisor edits tickets directly (no push needed - it IS the origin):
```bash
# Supervisor's ticket operations work locally
# Other workers see changes on next pull
```

For supervisor changes to trigger hooks, it commits and the post-receive logic runs on commit (or a post-commit hook mirrors the logic).

## Future Considerations

### Remote ticket origins

For distributed teams, the origin could be a hosted repo:
```bash
ralphs init --ticket-remote git@github.com:org/project-tickets.git
```

Workers and supervisor all clone from/push to the remote.

### Central ticket index

Optional `~/.claude/ralphs/index.json` tracking all projects:
```json
{
  "a1b2c3d4e5f6": {
    "path": "/home/user/myproject",
    "name": "myproject",
    "last_accessed": "2024-01-15T10:30:00Z"
  }
}
```

### Cross-project dependencies

Tickets could reference tickets in other projects:
```yaml
depends_on:
  - tk-1234                    # Same project
  - proj:abc123:tk-5678        # Other project
```
