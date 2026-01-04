#!/bin/bash
#
# pane.sh - tmux pane management
#

# Track pane assignments in a file
PANE_REGISTRY_FILE=".wiggum/panes.json"

# Send input to a pane, handling editor mode (vim/emacs keybinds)
# Usage: send_pane_input <session:window.pane> <message>
# Respects WIGGUM_EDITOR_MODE config: "normal" (default), "vim", "emacs"
send_pane_input() {
    local target="$1"
    local message="$2"

    if [[ "${WIGGUM_EDITOR_MODE:-normal}" == "vim" ]]; then
        # Vim mode: Escape to ensure normal mode, 'i' to insert, type message, Enter to submit
        tmux send-keys -t "$target" Escape
        sleep 0.2
        tmux send-keys -t "$target" "i"
        sleep 0.2
        # Send message as literal text, then Enter to submit
        tmux send-keys -t "$target" -l "$message"
        sleep 0.1
        tmux send-keys -t "$target" Enter
    else
        # Normal mode: just send message and Enter
        tmux send-keys -t "$target" -l "$message"
        sleep 0.1
        tmux send-keys -t "$target" Enter
    fi
}

# Get next agent index for a role
# Counts existing entries in the object-based registry with matching role
get_next_agent_index() {
    local role="$1"
    require_project

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ ! -f "$registry" ]] || [[ ! -s "$registry" ]]; then
        echo "0"
        return
    fi

    # Count keys that start with role- pattern using jq
    local count
    if command -v jq &>/dev/null; then
        count=$(jq --arg role "$role" '[keys[] | select(startswith($role + "-"))] | length' "$registry" 2>/dev/null || echo 0)
    else
        # Fallback: count matches of "role-" pattern in keys
        count=$(grep -c "\"${role}-[0-9]*\":" "$registry" 2>/dev/null || echo 0)
    fi
    # Ensure we have a valid number
    [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]] && count=0
    echo "$count"
}

# Look up ticket assigned to an agent by scanning tickets
# Usage: get_agent_ticket <agent-id>
# Returns: ticket ID or empty string if not assigned
get_agent_ticket() {
    local agent_id="$1"
    require_project

    # Scan MAIN tickets (canonical source of truth for observability)
    for ticket_file in "$MAIN_TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue
        local assigned
        assigned=$(get_frontmatter_value "$ticket_file" "assigned_agent_id" 2>/dev/null)
        if [[ "$assigned" == "$agent_id" ]]; then
            basename "$ticket_file" .md
            return
        fi
    done
}

# Register a pane in the object-based registry
# Usage: register_pane <agent-id> <role> <tmux-pane-id>
# Registry format: { "agent-id": { "role": "...", "tmux_pane_id": "...", "started_at": "..." } }
register_pane() {
    local agent_id="$1"
    local role="$2"
    local tmux_pane_id="${3:-}"

    require_project
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"

    # Initialize registry if needed
    if [[ ! -f "$registry" ]] || [[ ! -s "$registry" ]]; then
        echo "{}" >"$registry"
    fi

    local now
    now=$(timestamp)

    # Add entry to object using jq
    if command -v jq &>/dev/null; then
        local temp
        temp=$(mktemp)
        jq --arg id "$agent_id" \
            --arg role "$role" \
            --arg pane_id "$tmux_pane_id" \
            --arg started "$now" \
            '.[$id] = {"role": $role, "tmux_pane_id": $pane_id, "started_at": $started}' \
            "$registry" >"$temp" && mv "$temp" "$registry"
    else
        # Fallback without jq: simple append (less reliable)
        local content
        content=$(cat "$registry")
        local entry="\"$agent_id\": {\"role\": \"$role\", \"tmux_pane_id\": \"$tmux_pane_id\", \"started_at\": \"$now\"}"
        if [[ "$content" == "{}" ]]; then
            echo "{$entry}" >"$registry"
        else
            # Insert before closing brace
            echo "${content%\}}, $entry}" >"$registry"
        fi
    fi
}

# Unregister an agent from the object-based registry
# Usage: unregister_pane <agent-id>
unregister_pane() {
    local agent_id="$1"
    require_project

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    [[ -f "$registry" ]] || return 0

    # Delete key from object using jq
    if command -v jq &>/dev/null; then
        local temp
        temp=$(mktemp)
        jq --arg id "$agent_id" 'del(.[$id])' "$registry" >"$temp" && mv "$temp" "$registry"
    else
        # Fallback: recreate without the entry (less reliable)
        local temp
        temp=$(mktemp)
        grep -v "\"$agent_id\":" "$registry" >"$temp" 2>/dev/null || echo "{}" >"$temp"
        mv "$temp" "$registry"
    fi
}

# Look up tmux pane ID from registry by agent ID
# Usage: get_tmux_pane_id <agent-id>
# Returns: tmux pane ID (e.g., %5) or empty string if not found
get_tmux_pane_id() {
    local agent_id="$1"
    require_project
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"

    [[ -f "$registry" ]] || return 0

    if command -v jq &>/dev/null; then
        jq -r --arg id "$agent_id" '.[$id].tmux_pane_id // empty' "$registry" 2>/dev/null
    else
        # Fallback: grep for the entry
        local entry
        entry=$(grep "\"$agent_id\":" "$registry" 2>/dev/null || true)
        if [[ -n "$entry" ]]; then
            echo "$entry" | grep -o '"tmux_pane_id": "[^"]*"' | cut -d'"' -f4
        fi
    fi
}

# Build a prompt for an agent based on role and ticket
build_agent_prompt() {
    local role="$1"
    local ticket_id="${2:-}"
    local worktree_path="$3"

    # Find the prompt template (role name == prompt file name)
    local template=""
    local prompt_path="$PROMPTS_DIR/${role}.md"
    if [[ -f "$prompt_path" ]]; then
        template=$(cat "$prompt_path")
    elif [[ -f "$WIGGUM_DEFAULTS/prompts/${role}.md" ]]; then
        template=$(cat "$WIGGUM_DEFAULTS/prompts/${role}.md")
    else
        # No template found, return minimal prompt
        if [[ -n "$ticket_id" ]]; then
            echo "You are a $role agent. Your ticket is $ticket_id. Read the ticket at .wiggum/tickets/${ticket_id}.md and complete the work described."
        else
            echo "You are a $role agent for the wiggum multi-agent system."
        fi
        return
    fi

    # Substitute template variables
    local ticket_content=""
    local relevant_specs=""
    local project_specs=""
    local dependencies=""
    local feedback=""

    if [[ -n "$ticket_id" ]]; then
        local ticket_path="$TICKETS_DIR/${ticket_id}.md"
        if [[ -f "$ticket_path" ]]; then
            ticket_content=$(cat "$ticket_path")

            # Extract feedback section if present
            feedback=$(awk '/^## Feedback/,/^## [^F]|^$/' "$ticket_path" 2>/dev/null || true)

            # Extract dependencies
            dependencies=$(get_frontmatter_value "$ticket_path" "depends_on" || true)
        fi
    fi

    # Gather project specs (for supervisor)
    if [[ "$role" == "supervisor" ]] && [[ -d "$MAIN_PROJECT_ROOT/specs" ]]; then
        project_specs=$(find "$MAIN_PROJECT_ROOT/specs" -name "*.md" -exec basename {} \; 2>/dev/null | head -20 | tr '\n' ', ')
        project_specs="Available specs: $project_specs"
    fi

    # Perform substitutions
    template="${template//\{TICKET_ID\}/$ticket_id}"
    template="${template//\{TICKET_CONTENT\}/$ticket_content}"
    template="${template//\{RELEVANT_SPECS\}/$relevant_specs}"
    template="${template//\{PROJECT_SPECS\}/$project_specs}"
    template="${template//\{DEPENDENCIES\}/$dependencies}"
    template="${template//\{FEEDBACK\}/$feedback}"

    echo "$template"
}

# Spawn an agent in a new pane
cmd_spawn() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum spawn <role> [ticket-id] [--prompt PATH]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local role="$1"
    shift

    local ticket_id="${1:-}"
    [[ "$ticket_id" == --* ]] && ticket_id="" # Handle flags

    require_project
    load_config
    require_command tmux

    # Create session if it doesn't exist
    local new_session=false
    if ! session_exists "$WIGGUM_SESSION"; then
        info "Creating tmux session: $WIGGUM_SESSION"
        tmux new-session -d -s "$WIGGUM_SESSION" -n "main"
        new_session=true

        # Source wiggum tmux config
        local tmux_conf="$MAIN_WIGGUM_DIR/tmux.conf"
        [[ ! -f "$tmux_conf" ]] && tmux_conf="$WIGGUM_DEFAULTS/tmux.conf"
        [[ -f "$tmux_conf" ]] && tmux source-file "$tmux_conf" 2>/dev/null
    fi

    # Supervisor doesn't need a ticket
    if [[ "$role" != "supervisor" ]] && [[ -z "$ticket_id" ]]; then
        error "Ticket ID required for role: $role"
        exit "$EXIT_INVALID_ARGS"
    fi

    # Resolve ticket ID if provided
    if [[ -n "$ticket_id" ]]; then
        ticket_id=$(resolve_ticket_id "$ticket_id") || exit "$EXIT_TICKET_NOT_FOUND"
    fi

    # Build agent_id
    local agent_index
    agent_index=$(get_next_agent_index "$role")
    # Strip any whitespace/newlines that might have crept in
    agent_index="${agent_index//[$'\t\r\n ']/}"
    local agent_id="${role}-${agent_index}"

    # Build the agent command
    local agent_cmd="$WIGGUM_AGENT_CMD"

    # Create a worktree for the agent (always under main project)
    local worktree_path="$MAIN_PROJECT_ROOT/worktrees/$agent_id"
    local worktree_existed=false
    if [[ -d "$worktree_path" ]]; then
        worktree_existed=true
        debug "Reusing existing worktree for $agent_id"
    else
        info "Creating worktree for $agent_id..."
        mkdir -p "$MAIN_PROJECT_ROOT/worktrees"

        # Determine the starting branch for the worktree
        # For reviewer/QA roles, branch from the implementer's branch to see their changes
        local start_point=""
        if [[ "$role" != "worker" ]] && [[ "$role" != "supervisor" ]] && [[ -n "$ticket_id" ]]; then
            # Read assigned_agent_id from bare repo (source of truth)
            local impl_agent
            local ticket_content
            ticket_content=$(bare_read_ticket "${ticket_id}.md" 2>/dev/null)
            impl_agent=$(echo "$ticket_content" | awk '/^assigned_agent_id:/{print $2; exit}')
            if [[ -n "$impl_agent" ]]; then
                # Check if the implementer's branch exists
                if git rev-parse --verify "$impl_agent" &>/dev/null; then
                    start_point="$impl_agent"
                    info "Branching from implementer: $impl_agent"
                fi
            fi
        fi

        # Create the worktree
        local worktree_created=false
        if [[ -n "$start_point" ]]; then
            # Branch from implementer's branch
            if git worktree add "$worktree_path" -b "$agent_id" "$start_point" --quiet 2>&1 ||
               git worktree add "$worktree_path" "$agent_id" --quiet 2>&1; then
                worktree_created=true
            fi
        else
            # Default: branch from HEAD
            if git worktree add "$worktree_path" -b "$agent_id" --quiet 2>&1 ||
               git worktree add "$worktree_path" "$agent_id" --quiet 2>&1; then
                worktree_created=true
            fi
        fi

        if [[ "$worktree_created" != "true" ]]; then
            error "Failed to create worktree for $agent_id"
            exit "$EXIT_ERROR"
        fi

        # Symlink Claude Code settings from main project
        if [[ -d "$MAIN_PROJECT_ROOT/.claude" ]] && [[ -d "$worktree_path" ]] && [[ ! -e "$worktree_path/.claude" ]]; then
            ln -s "$MAIN_PROJECT_ROOT/.claude" "$worktree_path/.claude"
        fi
    fi

    # Ensure caller's tickets are pushed to bare repo before cloning to new worktree
    # (fixes issue where supervisor creates ticket but worker doesn't see it)
    if [[ -d "$TICKETS_DIR/.git" ]]; then
        debug "Syncing caller's tickets before clone"
        ticket_sync_push "Pre-spawn sync" 2>/dev/null || true
    fi

    # ALWAYS ensure .wiggum directory and fresh tickets clone exist
    # (fixes stale tickets from previous sessions when worktree is reused)
    mkdir -p "$worktree_path/.wiggum"
    if [[ "$worktree_existed" == "true" ]] && [[ -d "$worktree_path/.wiggum/tickets/.git" ]]; then
        # Worktree exists with tickets clone - pull latest
        debug "Refreshing tickets in existing worktree"
        git -C "$worktree_path/.wiggum/tickets" fetch origin --quiet 2>/dev/null || true
        git -C "$worktree_path/.wiggum/tickets" reset --hard origin/main --quiet 2>/dev/null || true
    else
        # Fresh clone needed
        clone_tickets_to_worktree "$worktree_path/.wiggum" || true
    fi

    # Create new pane
    info "Spawning $agent_id${ticket_id:+ for $ticket_id}..."

    local tmux_pane_id
    if [[ "$new_session" == "true" ]]; then
        # Reuse the initial pane created with the session - get its pane_id
        tmux_pane_id=$(tmux display-message -t "$WIGGUM_SESSION:main" -p '#{pane_id}')
    else
        # Split window to create new pane
        tmux split-window -t "$WIGGUM_SESSION:main" -h
        tmux_pane_id=$(tmux display-message -t "$WIGGUM_SESSION:main" -p '#{pane_id}')
    fi

    # Set pane title (include ticket if assigned)
    local pane_title="$agent_id"
    [[ -n "$ticket_id" ]] && pane_title="$agent_id:$ticket_id"
    tmux select-pane -t "$tmux_pane_id" -T "$pane_title"

    # Change to worktree directory
    tmux send-keys -t "$tmux_pane_id" "cd '$worktree_path'" Enter

    # Build the agent prompt
    local prompt
    prompt=$(build_agent_prompt "$role" "$ticket_id" "$worktree_path")

    # Write prompt to a file in the worktree for the agent to read
    local prompt_file="$worktree_path/.wiggum/current_prompt.md"
    echo "$prompt" >"$prompt_file"

    # Start the agent
    tmux send-keys -t "$tmux_pane_id" "$agent_cmd" Enter

    # Wait for agent to initialize (give it time to show welcome banner)
    sleep 6

    # Send the initial prompt using vim-safe input
    local initial_msg="Please read your role instructions from .wiggum/current_prompt.md and begin your work. Your role is: $role${ticket_id:+, assigned ticket: $ticket_id}"
    send_pane_input "$tmux_pane_id" "$initial_msg"

    # Apply layout
    tmux select-layout -t "$WIGGUM_SESSION:main" "$WIGGUM_LAYOUT" 2>/dev/null || true

    # Register the pane (agent_id -> tmux_pane_id mapping)
    register_pane "$agent_id" "$role" "$tmux_pane_id"

    # Start work on ticket if it's ready (assigning a ticket to any agent starts it)
    # IMPORTANT: Read state from BARE REPO (source of truth) to avoid race conditions
    # with stale clones. See: main clone sync bug.
    if [[ -n "$ticket_id" ]]; then
        local current_state
        local ticket_content
        ticket_content=$(bare_read_ticket "${ticket_id}.md")
        current_state=$(echo "$ticket_content" | awk '/^state:/{print $2; exit}')

        if [[ "$current_state" == "ready" ]]; then
            # Use ticket functions instead of direct frontmatter manipulation
            ticket_transition "$ticket_id" "in-progress"
            ticket_assign "$ticket_id" "$agent_id"
            run_hook "on-claim" "$ticket_id"
        fi
    fi

    # Show success message only when interactive (TTY)
    if [[ -t 1 ]]; then
        success "Spawned $agent_id"
    fi
    echo "$agent_id"
}

# List active agents
cmd_list() {
    local format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --format)
            format="$2"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project
    load_config

    if ! session_exists "$WIGGUM_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"

    case "$format" in
    json)
        if [[ -f "$registry" ]]; then
            cat "$registry"
        else
            echo "{}"
        fi
        ;;
    ids)
        # List agent IDs (object keys)
        if [[ -f "$registry" ]] && command -v jq &>/dev/null; then
            jq -r 'keys[]' "$registry" 2>/dev/null
        elif [[ -f "$registry" ]]; then
            grep -o '"[^"]*":' "$registry" | tr -d '":' | grep -v '^$'
        fi
        ;;
    table | *)
        echo ""
        printf "${BOLD}%-12s %-12s %-12s %-10s${NC}\n" "AGENT" "ROLE" "TICKET" "UPTIME"
        echo "------------------------------------------------"

        if [[ -f "$registry" ]] && command -v jq &>/dev/null; then
            # Use jq for proper JSON parsing of object-based registry
            local keys
            keys=$(jq -r 'keys[]' "$registry" 2>/dev/null)
            for agent_id in $keys; do
                local role started uptime ticket
                role=$(jq -r --arg id "$agent_id" '.[$id].role' "$registry")
                started=$(jq -r --arg id "$agent_id" '.[$id].started_at' "$registry")
                uptime=$(duration_since "$started")
                # Get ticket from tickets (single source of truth)
                ticket=$(get_agent_ticket "$agent_id")
                printf "%-12s %-12s %-12s %-10s\n" "$agent_id" "$role" "${ticket:-—}" "$uptime"
            done
        elif [[ -f "$registry" ]]; then
            # Fallback: parse JSON without jq (less reliable)
            warn "jq not found, using basic parsing"
            # Extract agent IDs from object keys
            local agent_ids
            agent_ids=$(grep -o '"[^"]*":' "$registry" | tr -d '":' | grep -v '^$')
            for agent_id in $agent_ids; do
                # Basic extraction - look for the agent's entry
                local role started uptime ticket
                local entry
                entry=$(grep -o "\"$agent_id\":[^}]*}" "$registry" 2>/dev/null || true)
                role=$(echo "$entry" | grep -o '"role"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
                started=$(echo "$entry" | grep -o '"started_at"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
                if [[ -n "$role" ]]; then
                    uptime=$(duration_since "$started")
                    ticket=$(get_agent_ticket "$agent_id")
                    printf "%-12s %-12s %-12s %-10s\n" "$agent_id" "$role" "${ticket:-—}" "$uptime"
                fi
            done
        fi
        echo ""
        ;;
    esac
}

# Kill an agent pane
cmd_kill() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum kill <agent-id> [--release-ticket]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local agent_id="$1"
    shift
    local release_ticket=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --release-ticket | --release)
            release_ticket=true
            shift
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project
    load_config

    if ! session_exists "$WIGGUM_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Get tmux pane ID from registry
    local tmux_pane_id
    tmux_pane_id=$(get_tmux_pane_id "$agent_id")

    # Get ticket from tickets (single source of truth)
    local ticket_id
    ticket_id=$(get_agent_ticket "$agent_id")

    # Kill the tmux pane by pane ID
    if [[ -n "$tmux_pane_id" ]]; then
        tmux kill-pane -t "$tmux_pane_id" 2>/dev/null &&
            info "Killed tmux pane"
    fi

    # Unregister
    unregister_pane "$agent_id"

    # Release ticket if requested
    if [[ "$release_ticket" == "true" ]] && [[ -n "$ticket_id" ]]; then
        # Use ticket functions instead of direct frontmatter manipulation
        ticket_unassign "$ticket_id"
        set_ticket_value "$ticket_id" "state" "ready" "Release ticket: $ticket_id"
        info "Released ticket $ticket_id"
    fi

    success "Killed $agent_id"
}

# Send a message to an agent pane
cmd_ping() {
    if [[ $# -lt 2 ]]; then
        error "Usage: wiggum ping <agent-id> <message>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local agent_id="$1"
    shift
    local message="$*"

    require_project
    load_config

    if ! session_exists "$WIGGUM_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Look up tmux pane ID from registry
    local tmux_pane_id
    tmux_pane_id=$(get_tmux_pane_id "$agent_id")

    if [[ -z "$tmux_pane_id" ]]; then
        error "Agent not found in registry: $agent_id"
        exit "$EXIT_PANE_NOT_FOUND"
    fi

    # Send the message using vim-safe input
    send_pane_input "$tmux_pane_id" "$message"

    success "Pinged $agent_id"
}

# Check if there's capacity for more workers
cmd_has_capacity() {
    require_project
    load_config

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    local current=0

    if [[ -f "$registry" ]] && command -v jq &>/dev/null; then
        # Count all entries, subtract supervisors
        local total supervisors
        total=$(jq 'keys | length' "$registry" 2>/dev/null || echo 0)
        supervisors=$(jq '[keys[] | select(startswith("supervisor-"))] | length' "$registry" 2>/dev/null || echo 0)
        current=$((total - supervisors))
    elif [[ -f "$registry" ]]; then
        # Fallback: count keys excluding supervisor-*
        current=$(grep -c '"worker-\|"reviewer-\|"qa-' "$registry" 2>/dev/null || echo 0)
    fi

    if [[ $current -lt $WIGGUM_MAX_AGENTS ]]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}
