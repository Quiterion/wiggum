#!/bin/bash
#
# ticket_types.sh - Ticket type configuration management
#
# Provides configurable ticket states, transitions, and hooks.
# Configuration is loaded from .wiggum/ticket_types.json or defaults.
#

# Cache for loaded configuration
_TICKET_TYPES_LOADED=false
_TICKET_TYPES_CONFIG=""

# Load ticket types configuration
# Caches the config for subsequent calls
load_ticket_types() {
    if [[ "$_TICKET_TYPES_LOADED" == "true" ]] && [[ -n "$_TICKET_TYPES_CONFIG" ]]; then
        return 0
    fi

    local config_path=""

    # Try project config first (from main project)
    if [[ -n "${MAIN_WIGGUM_DIR:-}" ]] && [[ -f "$MAIN_WIGGUM_DIR/ticket_types.json" ]]; then
        config_path="$MAIN_WIGGUM_DIR/ticket_types.json"
    elif [[ -f "$WIGGUM_DEFAULTS/ticket_types.json" ]]; then
        config_path="$WIGGUM_DEFAULTS/ticket_types.json"
    fi

    if [[ -z "$config_path" ]]; then
        debug "No ticket_types.json found, using hardcoded defaults"
        _TICKET_TYPES_CONFIG=""
        _TICKET_TYPES_LOADED=true
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        debug "jq not found, using hardcoded defaults for ticket types"
        _TICKET_TYPES_CONFIG=""
        _TICKET_TYPES_LOADED=true
        return 0
    fi

    _TICKET_TYPES_CONFIG=$(cat "$config_path")
    _TICKET_TYPES_LOADED=true
    debug "Loaded ticket types from $config_path"
}

# Reset cached configuration (for testing)
reset_ticket_types_cache() {
    _TICKET_TYPES_LOADED=false
    _TICKET_TYPES_CONFIG=""
}

# Check if we have loaded config (vs using hardcoded defaults)
has_ticket_types_config() {
    load_ticket_types
    [[ -n "$_TICKET_TYPES_CONFIG" ]]
}

# Get list of valid states
# Returns space-separated list
get_valid_states() {
    load_ticket_types

    if [[ -n "$_TICKET_TYPES_CONFIG" ]] && command -v jq &>/dev/null; then
        echo "$_TICKET_TYPES_CONFIG" | jq -r '.states | join(" ")'
    else
        # Hardcoded fallback
        echo "ready in-progress review qa done closed"
    fi
}

# Get valid target states for a given source state
# Usage: get_valid_transitions <from_state>
# Returns space-separated list of valid target states
get_valid_transitions() {
    local from_state="$1"
    load_ticket_types

    if [[ -n "$_TICKET_TYPES_CONFIG" ]] && command -v jq &>/dev/null; then
        echo "$_TICKET_TYPES_CONFIG" | jq -r --arg state "$from_state" \
            '.transitions[$state].targets // [] | join(" ")'
    else
        # Hardcoded fallback (matches original TRANSITIONS array)
        case "$from_state" in
            ready) echo "in-progress closed" ;;
            in-progress) echo "review" ;;
            review) echo "qa in-progress done closed" ;;
            qa) echo "done in-progress closed" ;;
            *) echo "" ;;
        esac
    fi
}

# Check if a transition is valid
# Usage: is_valid_transition <from_state> <to_state>
# Returns 0 if valid, 1 if invalid
is_valid_transition() {
    local from_state="$1"
    local to_state="$2"

    local valid_targets
    valid_targets=$(get_valid_transitions "$from_state")

    [[ " $valid_targets " == *" $to_state "* ]]
}

# Get hooks for a transition
# Usage: get_transition_hooks <from_state> <to_state> <phase>
# phase: "pre" or "post"
# Returns space-separated list of hook names
get_transition_hooks() {
    local from_state="$1"
    local to_state="$2"
    local phase="$3"  # "pre" or "post"

    load_ticket_types

    if [[ -n "$_TICKET_TYPES_CONFIG" ]] && command -v jq &>/dev/null; then
        # Try to get target-specific hooks first
        local hooks
        hooks=$(echo "$_TICKET_TYPES_CONFIG" | jq -r --arg state "$from_state" \
            --arg target "$to_state" --arg phase "$phase" \
            '.transitions[$state].hooks[$phase][$target] // [] | if type == "array" then join(" ") else "" end')

        # If no target-specific hooks, try generic hooks for the phase
        if [[ -z "$hooks" ]]; then
            hooks=$(echo "$_TICKET_TYPES_CONFIG" | jq -r --arg state "$from_state" \
                --arg phase "$phase" \
                '.transitions[$state].hooks[$phase] | if type == "array" then join(" ") else "" end')
        fi

        echo "$hooks"
    else
        # Hardcoded fallback (matches original post-receive hook behavior)
        if [[ "$phase" == "post" ]]; then
            case "$from_state:$to_state" in
                ready:in-progress) echo "on-claim" ;;
                in-progress:review) echo "on-draft-done" ;;
                review:qa) echo "on-review-done" ;;
                review:in-progress) echo "on-review-rejected" ;;
                qa:done) echo "on-qa-done on-close" ;;
                qa:in-progress) echo "on-qa-rejected" ;;
                *) echo "" ;;
            esac
        else
            # No pre-hooks in hardcoded defaults (except pre-review which is new)
            echo ""
        fi
    fi
}

# Get valid ticket types
# Returns space-separated list
get_valid_ticket_types() {
    load_ticket_types

    if [[ -n "$_TICKET_TYPES_CONFIG" ]] && command -v jq &>/dev/null; then
        echo "$_TICKET_TYPES_CONFIG" | jq -r '.types | join(" ")'
    else
        echo "feature bug task epic chore"
    fi
}

# Get default ticket type
get_default_ticket_type() {
    load_ticket_types

    if [[ -n "$_TICKET_TYPES_CONFIG" ]] && command -v jq &>/dev/null; then
        echo "$_TICKET_TYPES_CONFIG" | jq -r '.default_type // "task"'
    else
        echo "task"
    fi
}
