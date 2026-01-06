#!/bin/bash
#
# sync.sh - Distributed ticket synchronization
#
# Provides git-based synchronization for tickets across worktrees.
# See specs/wiggum/distributed-tickets.md for architecture details.
#

# Configuration
: "${WIGGUM_AUTO_SYNC:=true}"

# Check if current tickets dir is the bare repo (origin)
# This is used to skip sync operations when we're somehow in the bare repo context
is_ticket_origin() {
    # Bare repos don't have .git subdirectory - they ARE the git directory
    [[ ! -d "$TICKETS_DIR/.git" ]] && [[ -d "$TICKETS_DIR/objects" ]]
}

# Get the bare repo path (works from main project or worktree)
get_bare_repo() {
    if is_ticket_origin; then
        echo "$TICKETS_DIR"
    else
        echo "$MAIN_WIGGUM_DIR/tickets.git"
    fi
}

# List ticket files from bare repo
bare_list_tickets() {
    local bare_repo
    bare_repo=$(get_bare_repo)
    git -C "$bare_repo" ls-tree --name-only HEAD | grep '\.md$' | grep -v '^\.gitkeep'
}

# Read ticket content from bare repo
bare_read_ticket() {
    local ticket_file="$1"
    local bare_repo
    bare_repo=$(get_bare_repo)
    git -C "$bare_repo" show "HEAD:$ticket_file"
}

# Get frontmatter value from ticket in bare repo
bare_get_frontmatter_value() {
    local ticket_file="$1"
    local key="$2"
    bare_read_ticket "$ticket_file" | awk -v key="$key" '
        /^---$/ { in_fm = !in_fm; next }
        in_fm && $1 == key":" { print $2; exit }
    '
}

# Write ticket to bare repo via temp clone
bare_write_ticket() {
    local ticket_file="$1"
    local content="$2"
    local commit_msg="${3:-Update ticket}"
    local bare_repo
    bare_repo=$(get_bare_repo)

    local tmp
    tmp=$(mktemp -d)
    git clone "$bare_repo" "$tmp" --quiet
    git -C "$tmp" config user.email "wiggum@local"
    git -C "$tmp" config user.name "wiggum"

    echo "$content" >"$tmp/$ticket_file"
    git -C "$tmp" add "$ticket_file"
    git -c commit.gpgsign=false -C "$tmp" commit -m "$commit_msg" --quiet || true
    git -C "$tmp" push origin main --quiet || true
    rm -rf "$tmp"
}

# Delete ticket from bare repo via temp clone
bare_delete_ticket() {
    local ticket_file="$1"
    local commit_msg="${2:-Delete ticket}"
    local bare_repo
    bare_repo=$(get_bare_repo)

    local tmp
    tmp=$(mktemp -d)
    git clone "$bare_repo" "$tmp" --quiet
    git -C "$tmp" config user.email "wiggum@local"
    git -C "$tmp" config user.name "wiggum"

    rm -f "$tmp/$ticket_file"
    git -C "$tmp" add -A
    git -c commit.gpgsign=false -C "$tmp" commit -m "$commit_msg" --quiet || true
    git -C "$tmp" push origin main --quiet || true
    rm -rf "$tmp"
}

# Initialize the bare tickets repository
init_bare_tickets_repo() {
    local tickets_git="$WIGGUM_DIR/tickets.git"

    if [[ -d "$tickets_git" ]]; then
        debug "Bare tickets repo already exists"
        return 0
    fi

    info "Creating bare tickets repository..."
    git init --bare "$tickets_git" --quiet

    # Install hooks on bare repo
    install_bare_repo_hooks "$tickets_git"

    # Configure merge strategy for markdown
    echo "*.md merge=union" >"$tickets_git/info/attributes"

    # Create initial commit via temp clone
    local tmp
    tmp=$(mktemp -d)
    git clone "$tickets_git" "$tmp" --quiet || true
    git -C "$tmp" config user.email "wiggum@local"
    git -C "$tmp" config user.name "wiggum"
    # Create initial branch explicitly
    git -C "$tmp" checkout -b main || true
    touch "$tmp/.gitkeep"
    git -C "$tmp" add .
    git -c commit.gpgsign=false -C "$tmp" commit -m "Initial commit" --quiet || true
    git -C "$tmp" push -u origin main --quiet || true
    rm -rf "$tmp"

    # Set HEAD to main branch
    git -C "$tickets_git" symbolic-ref HEAD refs/heads/main || true

    success "Created bare tickets repository"
}

# Install bare repo hooks (DEPRECATED - now a no-op)
#
# As of the ticket refactor, hooks are now invoked DIRECTLY from
# ticket_transition() instead of from git hooks. This gives us:
#   - Pre-transition hooks (can block transitions)
#   - Post-transition hooks (run after successful sync)
#   - Proper environment (worktree context, not bare repo)
#
# Transition validation is now done in ticket_transition() using ticket_types.sh.
# Main clone auto-sync is handled by ticket_sync_push() calling operations
# that naturally trigger updates.
#
install_bare_repo_hooks() {
    local bare_repo="$1"
    # No-op: bare repo hooks have been removed
    # All validation and hook invocation happens in ticket_transition()
    debug "Bare repo hooks disabled - using ticket_transition() for validation and hooks"
}

# Clone tickets repo into a worktree's .wiggum directory
clone_tickets_to_worktree() {
    local worktree_wiggum="$1"
    local bare_repo="$MAIN_WIGGUM_DIR/tickets.git"

    if [[ ! -d "$bare_repo" ]]; then
        warn "Bare tickets repo not found, skipping clone"
        return 1
    fi

    local tickets_clone="$worktree_wiggum/tickets"

    if [[ -d "$tickets_clone/.git" ]]; then
        debug "Tickets already cloned to worktree"
        return 0
    fi

    # Remove plain tickets dir if exists (replace with clone)
    [[ -d "$tickets_clone" ]] && rm -rf "$tickets_clone"

    # Clone from bare repo
    git clone "$bare_repo" "$tickets_clone" --quiet

    # Configure user for commits
    git -C "$tickets_clone" config user.email "wiggum@local"
    git -C "$tickets_clone" config user.name "wiggum"

    success "Cloned tickets repo to worktree"
}

# Pull latest tickets from origin
ticket_sync_pull() {
    is_ticket_origin && return 0
    [[ "$WIGGUM_AUTO_SYNC" == "false" ]] && return 0

    require_project

    # Only sync if we have a clone
    [[ ! -d "$TICKETS_DIR/.git" ]] && return 0

    # Check for uncommitted changes that would block rebase
    if ! git -C "$TICKETS_DIR" diff --quiet ||
        ! git -C "$TICKETS_DIR" diff --cached --quiet; then
        warn "Ticket sync pull blocked: uncommitted changes in $TICKETS_DIR"
        warn "Run: git -C $TICKETS_DIR status"
        return 1
    fi

    if ! git -C "$TICKETS_DIR" fetch origin --quiet 2>&1; then
        warn "Ticket sync fetch failed for $TICKETS_DIR"
        return 1
    fi

    if ! git -C "$TICKETS_DIR" rebase origin/main --quiet 2>&1; then
        if ! git -C "$TICKETS_DIR" rebase origin/master --quiet 2>&1; then
            warn "Ticket sync rebase failed - resolve manually: git -C $TICKETS_DIR rebase --continue"
            return 1
        fi
    fi
}

# Push ticket changes to origin
ticket_sync_push() {
    is_ticket_origin && return 0
    [[ "$WIGGUM_AUTO_SYNC" == "false" ]] && return 0

    require_project

    # Only sync if we have a clone
    [[ ! -d "$TICKETS_DIR/.git" ]] && return 0

    local message="${1:-Ticket update}"

    # Stage changes
    if ! git -C "$TICKETS_DIR" add -A 2>&1; then
        warn "Ticket sync: git add failed in $TICKETS_DIR"
        return 1
    fi

    # Commit if there are staged changes
    if ! git -C "$TICKETS_DIR" diff --cached --quiet; then
        if ! git -c commit.gpgsign=false -C "$TICKETS_DIR" commit -m "$message" --quiet 2>&1; then
            warn "Ticket sync: commit failed in $TICKETS_DIR"
            return 1
        fi
    fi

    # Push to origin
    local push_output
    if ! push_output=$(git -C "$TICKETS_DIR" push origin main 2>&1); then
        if ! push_output=$(git -C "$TICKETS_DIR" push origin master 2>&1); then
            warn "Ticket sync: push failed in $TICKETS_DIR"
            warn "Push output: $push_output"
            warn "Hint: origin may have diverged. Try: git -C $TICKETS_DIR pull --rebase && git -C $TICKETS_DIR push"
            return 1
        fi
    fi
}

# Full sync (pull then push)
ticket_sync() {
    local mode="${1:-both}"

    require_project

    # Check if we have a clone (needed for sync)
    if [[ ! -d "$TICKETS_DIR/.git" ]]; then
        warn "No tickets clone found - run 'wiggum init' first"
        return 1
    fi

    case "$mode" in
    pull | --pull)
        ticket_sync_pull
        success "Pulled latest tickets"
        ;;
    push | --push)
        ticket_sync_push "Manual sync"
        success "Pushed ticket changes"
        ;;
    both | *)
        ticket_sync_pull
        ticket_sync_push "Manual sync"
        success "Synced tickets"
        ;;
    esac
}

# Add ticket sync subcommand
cmd_ticket_sync() {
    local mode="both"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --pull)
            mode="pull"
            shift
            ;;
        --push)
            mode="push"
            shift
            ;;
        *)
            shift
            ;;
        esac
    done

    ticket_sync "$mode"
}
