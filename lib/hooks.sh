#!/bin/bash
#
# hooks.sh - Hook execution system
#
# Hooks are shell scripts triggered by ticket state transitions.
# They encode the pipeline logic.
#

# Run a hook if it exists
run_hook() {
    local hook_name="$1"
    local ticket_id="$2"

    require_project
    load_config

    # Look for hook in project, then defaults
    local hook_path=""

    if [[ -x "$HOOKS_DIR/$hook_name" ]]; then
        hook_path="$HOOKS_DIR/$hook_name"
    elif [[ -x "$RALPHS_DEFAULTS/hooks/$hook_name" ]]; then
        hook_path="$RALPHS_DEFAULTS/hooks/$hook_name"
    else
        debug "No hook found: $hook_name"
        return 0
    fi

    debug "Running hook: $hook_path"

    # Set up environment
    export RALPHS_TICKET_ID="$ticket_id"
    export RALPHS_TICKET_PATH="$TICKETS_DIR/${ticket_id}.md"
    export RALPHS_SESSION
    export RALPHS_HOOKS_DIR="$HOOKS_DIR"

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

# List available hooks
list_hooks() {
    require_project

    echo "Project hooks (.ralphs/hooks/):"
    if [[ -d "$HOOKS_DIR" ]]; then
        for hook in "$HOOKS_DIR"/*; do
            [[ -f "$hook" ]] || continue
            local name=$(basename "$hook")
            local status="inactive"
            [[ -x "$hook" ]] && status="active"
            echo "  $name ($status)"
        done
    fi

    echo ""
    echo "Default hooks:"
    if [[ -d "$RALPHS_DEFAULTS/hooks" ]]; then
        for hook in "$RALPHS_DEFAULTS/hooks"/*; do
            [[ -f "$hook" ]] || continue
            echo "  $(basename "$hook")"
        done
    fi
}
