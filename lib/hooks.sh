#!/bin/bash
#
# hooks.sh - Hook execution system
#
# Hooks are shell scripts triggered by ticket state transitions.
# They encode the pipeline logic.
#

# Run a hook if it exists
# Note: Hooks are invoked from ticket_transition() which ensures the clone is synced
run_hook() {
    local hook_name="$1"
    local ticket_id="$2"

    require_project
    load_config

    # Look for hook in project, then defaults
    local hook_path=""

    if [[ -x "$HOOKS_DIR/$hook_name" ]]; then
        hook_path="$HOOKS_DIR/$hook_name"
    elif [[ -x "$WIGGUM_DEFAULTS/hooks/$hook_name" ]]; then
        hook_path="$WIGGUM_DEFAULTS/hooks/$hook_name"
    else
        debug "No hook found: $hook_name"
        return 0
    fi

    debug "Running hook: $hook_path"

    # Set up environment - read from clone (synced by ticket_transition)
    # The CRUD layer ensures clone is up to date before any operation
    local ticket_content
    ticket_content=$(read_ticket_content "$ticket_id" 2>/dev/null)

    export WIGGUM_TICKET_ID="$ticket_id"
    local ticket_path_val
    ticket_path_val=$(_ticket_path "$ticket_id")
    export WIGGUM_TICKET_PATH="$ticket_path_val"
    export WIGGUM_TICKET_CONTENT="$ticket_content"
    export WIGGUM_SESSION
    export WIGGUM_HOOKS_DIR="$HOOKS_DIR"
    # Export the wiggum binary path so hooks use the same version
    # (important for worktree-based development and testing)
    export WIGGUM_BIN="${WIGGUM_BIN:-$(command -v wiggum)}"
    # WIGGUM_PREV_STATE and WIGGUM_NEW_STATE set by ticket_transition()
    # WIGGUM_AGENT_ID computed from ticket
    if [[ -n "$ticket_content" ]]; then
        WIGGUM_AGENT_ID=$(echo "$ticket_content" | awk '/^assigned_agent_id:/{print $2; exit}')
        export WIGGUM_AGENT_ID
    fi

    # Run the hook
    if "$hook_path" "$ticket_id"; then
        debug "Hook completed: $hook_name"
        return 0
    else
        local exit_code=$?
        warn "Hook failed: $hook_name (exit $exit_code)"
        return $exit_code
    fi
}

# Hook subcommand router
cmd_hook() {
    if [[ $# -eq 0 ]]; then
        error "Usage: wiggum hook <run|list> [args]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local subcmd="$1"
    shift

    case "$subcmd" in
    run)
        if [[ $# -lt 2 ]]; then
            error "Usage: wiggum hook run <hook-name> <ticket-id>"
            exit "$EXIT_INVALID_ARGS"
        fi
        run_hook "$1" "$2"
        ;;
    list)
        list_hooks
        ;;
    *)
        error "Unknown hook subcommand: $subcmd"
        exit "$EXIT_INVALID_ARGS"
        ;;
    esac
}

# List available hooks
list_hooks() {
    require_project

    echo "Project hooks (.wiggum/hooks/):"
    if [[ -d "$HOOKS_DIR" ]]; then
        for hook in "$HOOKS_DIR"/*; do
            [[ -f "$hook" ]] || continue
            local name
            name=$(basename "$hook")
            local status="inactive"
            [[ -x "$hook" ]] && status="active"
            echo "  $name ($status)"
        done
    fi

    echo ""
    echo "Default hooks:"
    if [[ -d "$WIGGUM_DEFAULTS/hooks" ]]; then
        for hook in "$WIGGUM_DEFAULTS/hooks"/*; do
            [[ -f "$hook" ]] || continue
            echo "  $(basename "$hook")"
        done
    fi
}
