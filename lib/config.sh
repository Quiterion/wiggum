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

# Load configuration from file
load_config() {
    local config_path="${RALPHS_CONFIG_PATH:-}"

    # If no explicit path, try project config
    if [[ -z "$config_path" ]]; then
        local project_root
        if project_root=$(get_project_root 2>/dev/null); then
            config_path="$project_root/.ralphs/config.sh"
        fi
    fi

    # Source config if it exists
    if [[ -f "$config_path" ]]; then
        debug "Loading config from $config_path"
        source "$config_path"
    fi

    # Set default session name if not set
    if [[ -z "$RALPHS_SESSION" ]]; then
        local dirname=$(basename "$(pwd)")
        RALPHS_SESSION="ralphs-${dirname}"
    fi
}

# Get current session name
get_session_name() {
    load_config
    echo "$RALPHS_SESSION"
}

# Write default config file
write_default_config() {
    local config_path="$1"
    local dirname=$(basename "$(pwd)")

    cat > "$config_path" <<EOF
#!/bin/bash
#
# ralphs configuration
#

# Session name for tmux
RALPHS_SESSION="ralphs-${dirname}"

# Max concurrent worker panes
RALPHS_MAX_WORKERS=4

# Poll interval for supervisor (seconds)
RALPHS_POLL_INTERVAL=10

# Inner harness command (claude, amp, aider, etc.)
RALPHS_AGENT_CMD="claude"

# tmux pane layout
RALPHS_LAYOUT="tiled"

# Editor for ticket editing
RALPHS_EDITOR="\${EDITOR:-vim}"
EOF
}
