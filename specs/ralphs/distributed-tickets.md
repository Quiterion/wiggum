# Distributed Tickets

This document specifies the distributed ticket system for multi-agent parallel development.

## Overview

When multiple agents work in parallel (each in their own git worktree), they need a synchronized view of ticket state. This spec describes how tickets are stored in a separate git repository and synchronized across worktrees using git's native mechanisms.

## Architecture

```
proj/                                  ← main project (human's workspace)
├── .ralphs/
│   ├── tickets.git/                   ← bare repo (origin), hooks live here
│   ├── tickets/                       ← clone (for CLI commands from main project)
│   ├── config.sh
│   ├── hooks/
│   └── prompts/
├── .gitignore                         ← includes .ralphs/tickets.git/, .ralphs/tickets/, worktrees/
├── src/...
└── worktrees/
    ├── supervisor/                    ← supervisor's worktree
    │   └── .ralphs/
    │       └── tickets/               ← clone
    ├── impl-0/
    │   └── .ralphs/
    │       └── tickets/               ← clone
    └── reviewer-0/
        └── .ralphs/
            └── tickets/               ← clone
```

### Key Principles

1. **Tickets repo is separate from project repo** - ticket churn doesn't pollute project history
2. **Bare repo is the origin** - everyone clones from it
3. **All contexts have a clone** - main project and each worktree has its own clone for local operations
4. **Supervisor in own worktree** - supervisor is just another worktree, not special to git
5. **Hooks fire on bare repo** - pre-receive validates, post-receive triggers actions

## How It Works

### Everyone is a clone

```
                    tickets.git (bare)
                    /     |     \
                   /      |      \
        supervisor    impl-0    reviewer-0
          (clone)    (clone)     (clone)
```

All agents (including supervisor) push to and pull from the bare repo. The supervisor's authority is a *process* concern (it orchestrates), not a *git* concern.

### Push flow

```
impl-0: edits ticket, commits, pushes to origin
            ↓
    pre-receive: validates state transition
            ↓
    push accepted
            ↓
    post-receive: triggers ralphs hooks (may spawn reviewer, notify supervisor, etc.)
```

## Initialization

### First-time init

```bash
ralphs init [--session NAME]
```

1. Create bare tickets repo:
   ```bash
   git init --bare .ralphs/tickets.git
   ```
2. Install pre-receive and post-receive hooks on bare repo
3. Create initial commit (via temp clone):
   ```bash
   tmp=$(mktemp -d)
   git clone .ralphs/tickets.git "$tmp"
   touch "$tmp/.gitkeep"
   git -C "$tmp" add . && git -C "$tmp" commit -m "Initial commit"
   git -C "$tmp" push origin main
   rm -rf "$tmp"
   ```
4. Clone tickets into main project:
   ```bash
   git clone .ralphs/tickets.git .ralphs/tickets
   ```
5. Add to project's `.gitignore`:
   ```
   .ralphs/tickets.git/
   .ralphs/tickets/
   worktrees/
   ```
6. Create tmux session, spawn supervisor agent, etc.

### Spawning workers

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
   git clone ../../.ralphs/tickets.git worktrees/<pane-name>/.ralphs/tickets
   ```
4. Register pane, start agent, etc.

## Synchronization

### Push (after changes)

```bash
# In any agent's .ralphs/tickets/
git add -A
git commit -m "Transition tk-1234: implement → review"
git push origin main
```

- pre-receive validates the state transition
- If invalid, push is rejected with helpful error
- If valid, post-receive triggers appropriate hooks

### Pull (before operations)

```bash
# In any agent's .ralphs/tickets/
git pull --rebase origin main
```

## Ticket Commands with Git Plumbing

### Sync helpers

```bash
# Check if this tickets dir is the origin (bare repo has no remote)
is_ticket_origin() {
    [[ ! -d "$TICKETS_DIR/.git" ]]  # bare repos have no .git subdir
}

ticket_sync_pull() {
    is_ticket_origin && return 0  # origin doesn't pull
    [[ "$RALPHS_AUTO_SYNC" == "false" ]] && return 0

    git -C "$TICKETS_DIR" fetch origin --quiet
    git -C "$TICKETS_DIR" rebase origin/main --quiet 2>/dev/null || {
        warn "Ticket sync conflict - please resolve manually"
        return 1
    }
}

ticket_sync_push() {
    is_ticket_origin && return 0  # origin doesn't push
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

## Origin Hooks

### pre-receive (validation)

Location: `.ralphs/tickets.git/hooks/pre-receive`

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

Location: `.ralphs/tickets.git/hooks/post-receive`

```bash
#!/bin/bash

# Find project root (hooks -> tickets.git -> .ralphs -> proj)
TICKETS_GIT="$(cd "$(dirname "$0")/.." && pwd)"
RALPHS_DIR="$(dirname "$TICKETS_GIT")"
PROJECT_ROOT="$(dirname "$RALPHS_DIR")"

# Source ralphs config if available
if [[ -f "$RALPHS_DIR/config.sh" ]]; then
    source "$RALPHS_DIR/config.sh"
fi

# Find ralphs binary
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
                "$RALPHS_BIN" hook run on-implement-done "$ticket_id" 2>/dev/null &
                ;;
            qa)
                "$RALPHS_BIN" hook run on-review-done "$ticket_id" 2>/dev/null &
                ;;
            implement)
                if [[ "$old_state" == "review" ]]; then
                    "$RALPHS_BIN" hook run on-review-rejected "$ticket_id" 2>/dev/null &
                elif [[ "$old_state" == "qa" ]]; then
                    "$RALPHS_BIN" hook run on-qa-rejected "$ticket_id" 2>/dev/null &
                fi
                ;;
            done)
                "$RALPHS_BIN" hook run on-qa-done "$ticket_id" 2>/dev/null &
                "$RALPHS_BIN" hook run on-close "$ticket_id" 2>/dev/null &
                ;;
        esac
    done
done
```

Note: Hooks run in background (`&`) to avoid blocking the push.

## Conflict Resolution

### Automatic (rebase)

Most conflicts resolve automatically with rebase since:
- Each worker typically edits different tickets (claimed/assigned to them)
- Body edits are append-mostly (feedback, notes accumulate)

### Manual escalation

If rebase fails:
1. Worker's sync command warns: "Ticket sync conflict"
2. Worker can manually resolve: `git -C .ralphs/tickets rebase --continue`
3. Or abort and ask supervisor for help

### Merge strategy for body content

Configure tickets repo to use union merge for markdown:
```bash
# In .ralphs/tickets.git/info/attributes
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

Config options in `.ralphs/config.sh`:

```bash
RALPHS_AUTO_SYNC=true|false         # Auto-sync on ticket operations (default: true)
```

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

### Human interaction

The human works in the main project directory (`proj/`). They can:
- View tickets: `ralphs ticket list` (reads from their local clone)
- Create tickets: creates locally, pushes to bare repo
- Attach to session: `ralphs attach` to observe/intervene

The main project has its own clone at `.ralphs/tickets/`, so all CLI commands work the same as in worktrees.

## Future Considerations

### Supervisor hierarchy

The architecture supports multiple supervisors and meta-supervisors:
```
worktrees/
├── meta-supervisor/           ← supervises supervisors
├── supervisor-0/              ← supervises impl-0, reviewer-0
├── supervisor-1/              ← supervises impl-1, reviewer-1
├── impl-0/
└── ...
```

Hierarchy would be tracked in config/tickets, not git topology.

### Remote ticket origins

For distributed teams, use a hosted bare repo:
```bash
ralphs init --ticket-remote git@github.com:org/project-tickets.git
```

Everyone clones from the remote instead of local `.ralphs/tickets.git`.
