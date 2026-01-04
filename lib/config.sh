#!/bin/bash
#
# config.sh - Configuration management
#

# Default configuration values
: "${RALPHS_SESSION:=""}"
: "${RALPHS_MAX_WORKERS:=4}"
: "${RALPHS_POLL_INTERVAL:=10}"
: "${RALPHS_AGENT_CMD:=claude}"
: "${RALPHS_LAYOUT:=tiled}"
: "${RALPHS_EDITOR:=${EDITOR:-vim}}"

# Auto-detect editor mode from agent's config if not explicitly set
detect_editor_mode() {
    # If already set, use that
    [[ -n "${RALPHS_EDITOR_MODE:-}" ]] && return

    # Only check Claude config if using claude as the agent
    if [[ "${RALPHS_AGENT_CMD:-}" == "claude" ]] || [[ "${RALPHS_AGENT_CMD:-}" == *"claude "* ]]; then
        local claude_config="$HOME/.claude.json"
        if [[ -f "$claude_config" ]]; then
            local mode
            if command -v jq &>/dev/null; then
                mode=$(jq -r '.editorMode // empty' "$claude_config" 2>/dev/null)
            else
                # Fallback: simple grep
                mode=$(grep -o '"editorMode"[[:space:]]*:[[:space:]]*"[^"]*"' "$claude_config" 2>/dev/null | sed 's/.*"\([^"]*\)"$/\1/')
            fi
            if [[ -n "$mode" ]]; then
                RALPHS_EDITOR_MODE="$mode"
                return
            fi
        fi
    fi

    # Default to normal
    RALPHS_EDITOR_MODE="normal"
}

: "${RALPHS_EDITOR_MODE:=}"  # Will be set by detect_editor_mode if empty

# Load configuration from file
load_config() {
    local config_path="${RALPHS_CONFIG_PATH:-}"

    # If no explicit path, try project config (from main project, not worktree)
    if [[ -z "$config_path" ]]; then
        local main_root
        if main_root=$(get_main_project_root 2>/dev/null); then
            config_path="$main_root/.ralphs/config.sh"
        fi
    fi

    # Source config if it exists
    if [[ -f "$config_path" ]]; then
        debug "Loading config from $config_path"
        # shellcheck source=/dev/null
        source "$config_path"
    fi

    # Set default session name if not set
    if [[ -z "$RALPHS_SESSION" ]]; then
        local main_root
        if main_root=$(get_main_project_root 2>/dev/null); then
            RALPHS_SESSION="ralphs-$(basename "$main_root")"
        else
            RALPHS_SESSION="ralphs-$(basename "$(pwd)")"
        fi
    fi

    # Auto-detect editor mode if not set
    detect_editor_mode
}

# Get current session name
get_session_name() {
    load_config
    echo "$RALPHS_SESSION"
}

# Write default config file
write_default_config() {
    local config_path="$1"
    local dirname
    dirname=$(basename "$(pwd)")

    cat > "$config_path" <<EOF
#!/bin/bash
#
# ralphs configuration
#
# Note: Environment variables take precedence over these defaults
#

# Session name for tmux
: "\${RALPHS_SESSION:=ralphs-${dirname}}"

# Max concurrent worker panes
: "\${RALPHS_MAX_WORKERS:=4}"

# Poll interval for supervisor (seconds)
: "\${RALPHS_POLL_INTERVAL:=10}"

# Inner harness command (claude, amp, aider, etc.)
: "\${RALPHS_AGENT_CMD:=claude}"

# tmux pane layout
: "\${RALPHS_LAYOUT:=tiled}"

# Editor for ticket editing
: "\${RALPHS_EDITOR:=\${EDITOR:-vim}}"
EOF
}
