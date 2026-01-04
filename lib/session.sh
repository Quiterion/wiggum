#!/bin/bash
#
# session.sh - tmux session management
#

# Check if session exists
session_exists() {
    local session="${1:-$(get_session_name)}"
    tmux has-session -t "$session" 2>/dev/null
}

# Initialize a new ralphs session
cmd_init() {
    local session_name=""
    local no_session=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session)
                session_name="$2"
                shift 2
                ;;
            --no-session)
                no_session=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit "$EXIT_INVALID_ARGS"
                ;;
        esac
    done

    # Check if already in a ralphs project (handles running from subdirs or .ralphs/tickets/)
    local project_root
    if project_root=$(get_project_root 2>/dev/null); then
        info "Already in ralphs project at $project_root"
        cd "$project_root" || exit "$EXIT_ERROR"
    else
        # Find git root - ralphs must be initialized at the repo root
        local git_root
        if ! git_root=$(get_git_root); then
            error "Not in a git repository. Run 'git init' first."
            exit "$EXIT_ERROR"
        fi
        # Change to git root for all operations
        cd "$git_root" || exit "$EXIT_ERROR"
    fi

    # Create .ralphs directory structure
    local ralphs_dir=".ralphs"

    if [[ -d "$ralphs_dir" ]]; then
        info "ralphs directory already exists"
    else
        info "Creating ralphs directory structure..."
        mkdir -p "$ralphs_dir/hooks"
        mkdir -p "$ralphs_dir/prompts"
        mkdir -p "$ralphs_dir/tools"
    fi

    # Set PROJECT_ROOT and RALPHS_DIR for sync functions
    PROJECT_ROOT="$(pwd)"
    RALPHS_DIR="$PROJECT_ROOT/.ralphs"
    TICKETS_DIR="$RALPHS_DIR/tickets"
    export PROJECT_ROOT RALPHS_DIR TICKETS_DIR

    # Initialize bare tickets repository
    init_bare_tickets_repo

    # Clone tickets to local .ralphs/tickets for main worktree
    if [[ ! -d "$TICKETS_DIR/.git" ]]; then
        clone_tickets_to_worktree "$RALPHS_DIR"
    fi

    # Add to .gitignore
    local gitignore=".gitignore"
    [[ -f "$gitignore" ]] || touch "$gitignore"
    local entries=(".ralphs/tickets.git/" ".ralphs/tickets/" "worktrees/")
    for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
            echo "$entry" >> "$gitignore"
        fi
    done

    # Write config if not exists
    if [[ ! -f "$ralphs_dir/config.sh" ]]; then
        write_default_config "$ralphs_dir/config.sh"
        success "Created config.sh"
    fi

    # Copy default hooks if not present
    for hook in on-claim on-implement-done on-review-done on-review-rejected on-qa-done on-qa-rejected on-close; do
        if [[ ! -f "$ralphs_dir/hooks/$hook" ]] && [[ -f "$RALPHS_DEFAULTS/hooks/$hook" ]]; then
            cp "$RALPHS_DEFAULTS/hooks/$hook" "$ralphs_dir/hooks/"
            chmod +x "$ralphs_dir/hooks/$hook"
        fi
    done
    success "Hooks initialized"

    # Copy default prompts if not present
    for prompt in supervisor.md implementer.md reviewer.md qa.md; do
        if [[ ! -f "$ralphs_dir/prompts/$prompt" ]] && [[ -f "$RALPHS_DEFAULTS/prompts/$prompt" ]]; then
            cp "$RALPHS_DEFAULTS/prompts/$prompt" "$ralphs_dir/prompts/"
        fi
    done
    success "Prompts initialized"

    # Load config
    load_config

    # Skip session creation if requested (for testing)
    if [[ "$no_session" == "true" ]]; then
        success "ralphs initialized (no session)"
        return 0
    fi

    # Override session name if provided
    [[ -n "$session_name" ]] && RALPHS_SESSION="$session_name"

    # Check for tmux
    require_command tmux

    # Create tmux session if not exists
    if session_exists "$RALPHS_SESSION"; then
        info "Session '$RALPHS_SESSION' already exists"
    else
        info "Creating tmux session: $RALPHS_SESSION"
        tmux new-session -d -s "$RALPHS_SESSION" -n "main"
        success "Session created"
    fi

    success "ralphs initialized"
    echo ""
    echo "Next steps:"
    echo "  ralphs ticket create \"Your first task\" --type feature"
    echo "  ralphs spawn supervisor"
    echo "  ralphs attach"
}

# Attach to an existing session
cmd_attach() {
    local session_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session)
                session_name="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit "$EXIT_INVALID_ARGS"
                ;;
        esac
    done

    load_config
    [[ -n "$session_name" ]] && RALPHS_SESSION="$session_name"

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session '$RALPHS_SESSION' not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    tmux attach-session -t "$RALPHS_SESSION"
}

# Tear down the session
cmd_teardown() {
    local force=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            *)
                error "Unknown option: $1"
                exit "$EXIT_INVALID_ARGS"
                ;;
        esac
    done

    load_config

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session '$RALPHS_SESSION' not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Check for active workers unless force
    if [[ "$force" != "true" ]]; then
        local pane_count
    pane_count=$(tmux list-panes -t "$RALPHS_SESSION" 2>/dev/null | wc -l)
        if [[ $pane_count -gt 1 ]]; then
            warn "Active workers detected. Use --force to kill anyway."
            exit "$EXIT_ERROR"
        fi
    fi

    info "Tearing down session: $RALPHS_SESSION"
    tmux kill-session -t "$RALPHS_SESSION"
    success "Session terminated"
}
