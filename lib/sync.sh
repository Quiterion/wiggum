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
        echo "$WIGGUM_DIR/tickets.git"
    fi
}

# List ticket files from bare repo
bare_list_tickets() {
    local bare_repo
    bare_repo=$(get_bare_repo)
    git -C "$bare_repo" ls-tree --name-only HEAD 2>/dev/null | grep '\.md$' | grep -v '^\.gitkeep'
}

# Read ticket content from bare repo
bare_read_ticket() {
    local ticket_file="$1"
    local bare_repo
    bare_repo=$(get_bare_repo)
    git -C "$bare_repo" show "HEAD:$ticket_file" 2>/dev/null
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
    git clone "$bare_repo" "$tmp" --quiet 2>/dev/null
    git -C "$tmp" config user.email "wiggum@local"
    git -C "$tmp" config user.name "wiggum"

    echo "$content" > "$tmp/$ticket_file"
    git -C "$tmp" add "$ticket_file"
    git -c commit.gpgsign=false -C "$tmp" commit -m "$commit_msg" --quiet 2>/dev/null || true
    git -C "$tmp" push origin main --quiet 2>/dev/null || true
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
    git clone "$bare_repo" "$tmp" --quiet 2>/dev/null
    git -C "$tmp" config user.email "wiggum@local"
    git -C "$tmp" config user.name "wiggum"

    rm -f "$tmp/$ticket_file"
    git -C "$tmp" add -A
    git -c commit.gpgsign=false -C "$tmp" commit -m "$commit_msg" --quiet 2>/dev/null || true
    git -C "$tmp" push origin main --quiet 2>/dev/null || true
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
    echo "*.md merge=union" > "$tickets_git/info/attributes"

    # Create initial commit via temp clone
    local tmp
    tmp=$(mktemp -d)
    git clone "$tickets_git" "$tmp" --quiet 2>/dev/null || true
    git -C "$tmp" config user.email "wiggum@local"
    git -C "$tmp" config user.name "wiggum"
    # Create initial branch explicitly
    git -C "$tmp" checkout -b main 2>/dev/null || true
    touch "$tmp/.gitkeep"
    git -C "$tmp" add .
    git -c commit.gpgsign=false -C "$tmp" commit -m "Initial commit" --quiet 2>/dev/null || true
    git -C "$tmp" push -u origin main --quiet 2>/dev/null || true
    rm -rf "$tmp"

    # Set HEAD to main branch
    git -C "$tickets_git" symbolic-ref HEAD refs/heads/main 2>/dev/null || true

    success "Created bare tickets repository"
}

# Install pre-receive and post-receive hooks on bare repo
install_bare_repo_hooks() {
    local bare_repo="$1"
    local hooks_dir="$bare_repo/hooks"

    # Pre-receive hook for validation
    cat > "$hooks_dir/pre-receive" <<'HOOK'
#!/bin/bash
set -e

# State transition rules
declare -A TRANSITIONS=(
    ["ready"]="in-progress closed"
    ["in-progress"]="review"
    ["review"]="qa in-progress done closed"
    ["qa"]="done in-progress closed"
)

validate_transition() {
    local from="$1" to="$2"
    [[ " ${TRANSITIONS[$from]} " == *" $to "* ]]
}

while read -r oldrev newrev refname; do
    # Skip branch deletion
    [[ "$newrev" == "0000000000000000000000000000000000000000" ]] && continue

    # Get list of changed files
    files=""
    if [[ "$oldrev" == "0000000000000000000000000000000000000000" ]]; then
        files=$(git ls-tree -r --name-only "$newrev")
    else
        files=$(git diff --name-only "$oldrev" "$newrev" 2>/dev/null || echo "")
    fi

    # Check each changed ticket file
    for file in $files; do
        [[ "$file" == *.md ]] || continue
        [[ "$file" == ".gitkeep" ]] && continue

        # Get old and new state
        old_state=""
        if [[ "$oldrev" != "0000000000000000000000000000000000000000" ]]; then
            old_state=$(git show "$oldrev:$file" 2>/dev/null | awk '/^state:/{print $2}' || echo "")
        fi
        new_state=$(git show "$newrev:$file" 2>/dev/null | awk '/^state:/{print $2}' || echo "")

        # Skip if state unchanged (body-only edit)
        [[ "$old_state" == "$new_state" ]] && continue

        # New tickets must start at ready
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
            exit 1
        fi
    done
done

exit 0
HOOK
    chmod +x "$hooks_dir/pre-receive"

    # Post-receive hook for triggering wiggum hooks
    cat > "$hooks_dir/post-receive" <<'HOOK'
#!/bin/bash

# Find project root (hooks -> tickets.git -> .wiggum -> proj)
TICKETS_GIT="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_WIGGUM_DIR="$(dirname "$TICKETS_GIT")"
PROJECT_ROOT="$(dirname "$MAIN_WIGGUM_DIR")"

# Find wiggum binary
WIGGUM_BIN=$(command -v wiggum 2>/dev/null || echo "$PROJECT_ROOT/bin/wiggum")

while read -r oldrev newrev refname; do
    # Skip deletions
    [[ "$newrev" == "0000000000000000000000000000000000000000" ]] && continue
    [[ "$oldrev" == "0000000000000000000000000000000000000000" ]] && continue

    # Check each changed ticket
    for file in $(git diff --name-only "$oldrev" "$newrev" 2>/dev/null); do
        [[ "$file" == *.md ]] || continue

        ticket_id=$(basename "$file" .md)
        old_state=$(git show "$oldrev:$file" 2>/dev/null | awk '/^state:/{print $2}' || echo "")
        new_state=$(git show "$newrev:$file" 2>/dev/null | awk '/^state:/{print $2}' || echo "")

        [[ "$old_state" == "$new_state" ]] && continue

        # Export state info for hooks
        export WIGGUM_PREV_STATE="$old_state"
        export WIGGUM_NEW_STATE="$new_state"

        # Trigger appropriate hook via wiggum (background to avoid blocking)
        case "$new_state" in
            review)
                (cd "$PROJECT_ROOT" && "$WIGGUM_BIN" hook run on-draft-done "$ticket_id" 2>/dev/null &)
                ;;
            qa)
                (cd "$PROJECT_ROOT" && "$WIGGUM_BIN" hook run on-review-done "$ticket_id" 2>/dev/null &)
                ;;
            in-progress)
                if [[ "$old_state" == "review" ]]; then
                    (cd "$PROJECT_ROOT" && "$WIGGUM_BIN" hook run on-review-rejected "$ticket_id" 2>/dev/null &)
                elif [[ "$old_state" == "qa" ]]; then
                    (cd "$PROJECT_ROOT" && "$WIGGUM_BIN" hook run on-qa-rejected "$ticket_id" 2>/dev/null &)
                fi
                ;;
            done)
                (cd "$PROJECT_ROOT" && "$WIGGUM_BIN" hook run on-qa-done "$ticket_id" 2>/dev/null &)
                (cd "$PROJECT_ROOT" && "$WIGGUM_BIN" hook run on-close "$ticket_id" 2>/dev/null &)
                ;;
        esac
    done
done

# Update main clone for observability commands
MAIN_TICKETS="$MAIN_WIGGUM_DIR/tickets"
if [[ -d "$MAIN_TICKETS/.git" ]]; then
    git -C "$MAIN_TICKETS" pull --rebase --quiet 2>/dev/null || true
fi
HOOK
    chmod +x "$hooks_dir/post-receive"
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

    git -C "$TICKETS_DIR" fetch origin --quiet 2>/dev/null || return 0
    git -C "$TICKETS_DIR" rebase origin/main --quiet 2>/dev/null || \
        git -C "$TICKETS_DIR" rebase origin/master --quiet 2>/dev/null || {
        warn "Ticket sync conflict - resolve manually with: git -C $TICKETS_DIR rebase --continue"
        return 1
    }
}

# Push ticket changes to origin
ticket_sync_push() {
    is_ticket_origin && return 0
    [[ "$WIGGUM_AUTO_SYNC" == "false" ]] && return 0

    require_project

    # Only sync if we have a clone
    [[ ! -d "$TICKETS_DIR/.git" ]] && return 0

    local message="${1:-Ticket update}"

    # Stage and commit if there are changes
    git -C "$TICKETS_DIR" add -A 2>/dev/null || true
    git -C "$TICKETS_DIR" diff --cached --quiet 2>/dev/null || \
        git -c commit.gpgsign=false -C "$TICKETS_DIR" commit -m "$message" --quiet 2>/dev/null || true

    # Push to origin
    git -C "$TICKETS_DIR" push origin main --quiet 2>/dev/null || \
        git -C "$TICKETS_DIR" push origin master --quiet 2>/dev/null || true
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
        pull|--pull)
            ticket_sync_pull
            success "Pulled latest tickets"
            ;;
        push|--push)
            ticket_sync_push "Manual sync"
            success "Pushed ticket changes"
            ;;
        both|*)
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
