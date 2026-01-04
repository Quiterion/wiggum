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

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --session)
                session_name="$2"
                shift 2
                ;;
            *)
                error "Unknown option: $1"
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done

    # Create .ralphs directory structure
    local ralphs_dir=".ralphs"

    if [[ -d "$ralphs_dir" ]]; then
        info "ralphs directory already exists"
    else
        info "Creating ralphs directory structure..."
        mkdir -p "$ralphs_dir/tickets"
        mkdir -p "$ralphs_dir/hooks"
        mkdir -p "$ralphs_dir/prompts"
        mkdir -p "$ralphs_dir/tools"
    fi

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
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done

    load_config
    [[ -n "$session_name" ]] && RALPHS_SESSION="$session_name"

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session '$RALPHS_SESSION' not found"
        exit $EXIT_SESSION_NOT_FOUND
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
                exit $EXIT_INVALID_ARGS
                ;;
        esac
    done

    load_config

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session '$RALPHS_SESSION' not found"
        exit $EXIT_SESSION_NOT_FOUND
    fi

    # Check for active workers unless force
    if [[ "$force" != "true" ]]; then
        local pane_count
    pane_count=$(tmux list-panes -t "$RALPHS_SESSION" 2>/dev/null | wc -l)
        if [[ $pane_count -gt 1 ]]; then
            warn "Active workers detected. Use --force to kill anyway."
            exit $EXIT_ERROR
        fi
    fi

    info "Tearing down session: $RALPHS_SESSION"
    tmux kill-session -t "$RALPHS_SESSION"
    success "Session terminated"
}
