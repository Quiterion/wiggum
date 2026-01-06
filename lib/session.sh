#!/bin/bash
#
# session.sh - tmux session management
#

# Check if session exists
session_exists() {
    local session="${1:-$(get_session_name)}"
    tmux has-session -t "$session" 2>/dev/null
}

# Initialize a new wiggum project
cmd_init() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        *)
            error "Unknown option: $1"
            exit "$EXIT_INVALID_ARGS"
            ;;
        esac
    done

    # Check if already in a wiggum project (handles running from subdirs or .wiggum/tickets/)
    local project_root
    if project_root=$(get_project_root 2>/dev/null); then
        info "Already in wiggum project at $project_root"
        cd "$project_root" || exit "$EXIT_ERROR"
    else
        # Find git root - wiggum must be initialized at the repo root
        local git_root
        if ! git_root=$(get_git_root); then
            error "Not in a git repository. Run 'git init' first."
            exit "$EXIT_ERROR"
        fi
        # Change to git root for all operations
        cd "$git_root" || exit "$EXIT_ERROR"
    fi

    # Create .wiggum directory structure
    local wiggum_dir=".wiggum"

    if [[ -d "$wiggum_dir" ]]; then
        info "wiggum directory already exists"
    else
        info "Creating wiggum directory structure..."
        mkdir -p "$wiggum_dir/hooks"
        mkdir -p "$wiggum_dir/prompts"
    fi

    # Set PROJECT_ROOT and WIGGUM_DIR for sync functions
    PROJECT_ROOT="$(pwd)"
    MAIN_PROJECT_ROOT="$PROJECT_ROOT"
    WIGGUM_DIR="$PROJECT_ROOT/.wiggum"
    MAIN_WIGGUM_DIR="$WIGGUM_DIR"
    TICKETS_DIR="$WIGGUM_DIR/tickets"
    export PROJECT_ROOT MAIN_PROJECT_ROOT WIGGUM_DIR MAIN_WIGGUM_DIR TICKETS_DIR

    # Initialize bare tickets repository
    init_bare_tickets_repo

    # Clone tickets to local .wiggum/tickets for main worktree
    if [[ ! -d "$TICKETS_DIR/.git" ]]; then
        clone_tickets_to_worktree "$WIGGUM_DIR"
    fi

    # Add to .gitignore
    local gitignore=".gitignore"
    [[ -f "$gitignore" ]] || touch "$gitignore"
    local entries=(".wiggum/" "worktrees/")
    for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" "$gitignore" 2>/dev/null; then
            echo "$entry" >>"$gitignore"
        fi
    done

    # Create Claude Code settings for worktree agents if using Claude
    if [[ "${WIGGUM_AGENT_CMD:-}" == "claude" ]] || [[ "${WIGGUM_AGENT_CMD:-}" == *"claude "* ]]; then
        local claude_dir=".claude"
        if [[ ! -d "$claude_dir" ]]; then
            mkdir -p "$claude_dir"
        fi
        if [[ ! -f "$claude_dir/settings.local.json" ]]; then
            cat >"$claude_dir/settings.local.json" <<'CLAUDE_SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(wiggum *:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git status:*)",
      "Bash(git diff:*)",
      "Bash(git log:*)",
      "Bash(wiggum:*)"
    ]
  }
}
CLAUDE_SETTINGS
            success "Created Claude Code settings"
            # Add to gitignore
            if ! grep -qxF ".claude/settings.local.json" "$gitignore" 2>/dev/null; then
                echo ".claude/settings.local.json" >>"$gitignore"
            fi
        fi
    fi

    # Write config if not exists
    if [[ ! -f "$wiggum_dir/config.sh" ]]; then
        write_default_config "$wiggum_dir/config.sh"
        success "Created config.sh"
    fi

    # Copy default hooks if not present
    for hook in on-claim on-draft-done on-review-done on-review-rejected on-qa-done on-qa-rejected on-close; do
        if [[ ! -f "$wiggum_dir/hooks/$hook" ]] && [[ -f "$WIGGUM_DEFAULTS/hooks/$hook" ]]; then
            cp "$WIGGUM_DEFAULTS/hooks/$hook" "$wiggum_dir/hooks/"
            chmod +x "$wiggum_dir/hooks/$hook"
        fi
    done
    success "Hooks initialized"

    # Copy default tmux config if not present
    if [[ ! -f "$wiggum_dir/tmux.conf" ]] && [[ -f "$WIGGUM_DEFAULTS/tmux.conf" ]]; then
        cp "$WIGGUM_DEFAULTS/tmux.conf" "$wiggum_dir/tmux.conf"
        success "Created tmux.conf"
    fi

    # Copy default prompts if not present
    for prompt in supervisor.md worker.md reviewer.md qa.md; do
        if [[ ! -f "$wiggum_dir/prompts/$prompt" ]] && [[ -f "$WIGGUM_DEFAULTS/prompts/$prompt" ]]; then
            cp "$WIGGUM_DEFAULTS/prompts/$prompt" "$wiggum_dir/prompts/"
        fi
    done
    success "Prompts initialized"

    # Copy default ticket types configuration if not present
    if [[ ! -f "$wiggum_dir/ticket_types.json" ]] && [[ -f "$WIGGUM_DEFAULTS/ticket_types.json" ]]; then
        cp "$WIGGUM_DEFAULTS/ticket_types.json" "$wiggum_dir/ticket_types.json"
        success "Ticket types configuration initialized"
    fi

    success "wiggum initialized"
    echo ""
    echo "Next steps:"
    echo "  wiggum ticket create \"Your first task\" --type feature"
    echo "  wiggum spawn supervisor"
    echo "  wiggum attach"
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
    [[ -n "$session_name" ]] && WIGGUM_SESSION="$session_name"

    if ! session_exists "$WIGGUM_SESSION"; then
        error "Session '$WIGGUM_SESSION' not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    tmux attach-session -t "$WIGGUM_SESSION"
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

    require_project
    load_config

    if ! session_exists "$WIGGUM_SESSION"; then
        error "Session '$WIGGUM_SESSION' not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Check for active workers unless force
    if [[ "$force" != "true" ]]; then
        local pane_count
        pane_count=$(tmux list-panes -t "$WIGGUM_SESSION" 2>/dev/null | wc -l)
        if [[ $pane_count -gt 1 ]]; then
            warn "Active workers detected. Use --force to kill anyway."
            exit "$EXIT_ERROR"
        fi
    fi

    info "Tearing down session: $WIGGUM_SESSION"

    # Clean up worktrees and branches for all agents (same as cmd_kill)
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ -f "$registry" ]] && command -v jq &>/dev/null; then
        local agent_ids
        agent_ids=$(jq -r 'keys[]' "$registry" 2>/dev/null || true)
        for agent_id in $agent_ids; do
            # Clean up worktree
            local worktree_path="$MAIN_PROJECT_ROOT/worktrees/$agent_id"
            if [[ -d "$worktree_path" ]]; then
                info "Cleaning up worktree for $agent_id..."

                # Remove untracked files created by wiggum
                [[ -d "$worktree_path/.wiggum" ]] && rm -rf "$worktree_path/.wiggum"
                [[ -L "$worktree_path/.claude" ]] && rm -f "$worktree_path/.claude"
                [[ -d "$worktree_path/.claude" ]] && rm -rf "$worktree_path/.claude"

                local wt_args=()
                [[ "$force" == "true" ]] && wt_args+=("--force")

                if ! git worktree remove "${wt_args[@]}" "$worktree_path" 2>/dev/null; then
                    debug "Failed to remove worktree: $worktree_path"
                fi
            fi

            # Clean up branch
            if git rev-parse --verify "$agent_id" &>/dev/null; then
                info "Cleaning up branch $agent_id..."
                local branch_args=("-d")
                [[ "$force" == "true" ]] && branch_args=("-D")

                if ! git branch "${branch_args[@]}" "$agent_id" 2>/dev/null; then
                    debug "Failed to delete branch $agent_id"
                fi
            fi
        done
    fi

    # Kill the tmux session
    tmux kill-session -t "$WIGGUM_SESSION"

    # Clear the pane registry
    if [[ -f "$registry" ]]; then
        echo "{}" >"$registry"
    fi

    success "Session terminated"
}
