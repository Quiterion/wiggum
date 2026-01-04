#!/bin/bash
#
# pane.sh - tmux pane management
#

# Track pane assignments in a file
PANE_REGISTRY_FILE=".ralphs/panes.json"

# Get next pane index for a role
get_next_pane_index() {
    local role="$1"
    require_project

    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ ! -f "$registry" ]]; then
        echo "0"
        return
    fi

    # Count existing panes with this role
    local count
    count=$(grep -c "\"role\": \"$role\"" "$registry" 2>/dev/null || echo 0)
    echo "$count"
}

# Register a pane
register_pane() {
    local pane_id="$1"
    local role="$2"
    local ticket_id="${3:-}"

    require_project
    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"

    # Initialize registry if needed
    if [[ ! -f "$registry" ]]; then
        echo "[]" > "$registry"
    fi

    local now
    now=$(timestamp)
    local entry="{\"pane\": \"$pane_id\", \"role\": \"$role\", \"ticket\": \"$ticket_id\", \"started_at\": \"$now\"}"

    # Add to registry (simple append approach)
    local content
    content=$(cat "$registry")
    if [[ "$content" == "[]" ]]; then
        echo "[$entry]" > "$registry"
    else
        # Remove trailing ] and add new entry
        echo "${content%]}, $entry]" > "$registry"
    fi
}

# Unregister a pane
unregister_pane() {
    local pane_id="$1"
    require_project

    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    [[ -f "$registry" ]] || return 0

    # Filter out the pane (simple grep -v approach)
    local temp
    temp=$(mktemp)
    grep -v "\"pane\": \"$pane_id\"" "$registry" > "$temp" 2>/dev/null || echo "[]" > "$temp"

    # Fix JSON if needed
    local content
    content=$(cat "$temp")
    if [[ -z "$content" ]] || [[ "$content" == *","* && ! "$content" == *"{"* ]]; then
        echo "[]" > "$registry"
    else
        mv "$temp" "$registry"
    fi
    rm -f "$temp"
}

# Spawn an agent in a new pane
cmd_spawn() {
    if [[ $# -lt 1 ]]; then
        error "Usage: ralphs spawn <role> [ticket-id] [--prompt PATH]"
        exit $EXIT_INVALID_ARGS
    fi

    local role="$1"
    shift

    local ticket_id="${1:-}"
    [[ "$ticket_id" == --* ]] && ticket_id=""  # Handle flags

    require_project
    load_config

    # Validate session
    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found. Run 'ralphs init' first."
        exit $EXIT_SESSION_NOT_FOUND
    fi

    # Supervisor doesn't need a ticket
    if [[ "$role" != "supervisor" ]] && [[ -z "$ticket_id" ]]; then
        error "Ticket ID required for role: $role"
        exit $EXIT_INVALID_ARGS
    fi

    # Resolve ticket ID if provided
    if [[ -n "$ticket_id" ]]; then
        ticket_id=$(resolve_ticket_id "$ticket_id") || exit $EXIT_TICKET_NOT_FOUND
    fi

    # Build pane name
    local pane_index
    pane_index=$(get_next_pane_index "$role")
    local pane_name="${role}-${pane_index}"

    # Build the agent command
    local agent_cmd="$RALPHS_AGENT_CMD"

    # In distributed mode, create a worktree for the agent
    local worktree_path=""
    if is_distributed; then
        worktree_path="$PROJECT_ROOT/worktrees/$pane_name"
        if [[ ! -d "$worktree_path" ]]; then
            info "Creating worktree for $pane_name..."
            mkdir -p "$PROJECT_ROOT/worktrees"
            git worktree add "$worktree_path" -b "$pane_name" --quiet 2>/dev/null || \
                git worktree add "$worktree_path" "$pane_name" --quiet 2>/dev/null || true

            # Create .ralphs directory structure in worktree
            mkdir -p "$worktree_path/.ralphs/hooks"
            mkdir -p "$worktree_path/.ralphs/prompts"

            # Clone tickets repo into worktree
            clone_tickets_to_worktree "$worktree_path/.ralphs"

            # Copy hooks and prompts
            [[ -d "$RALPHS_DIR/hooks" ]] && cp -r "$RALPHS_DIR/hooks/"* "$worktree_path/.ralphs/hooks/" 2>/dev/null || true
            [[ -d "$RALPHS_DIR/prompts" ]] && cp -r "$RALPHS_DIR/prompts/"* "$worktree_path/.ralphs/prompts/" 2>/dev/null || true
        fi
    fi

    # Create new pane
    info "Spawning $pane_name${ticket_id:+ for $ticket_id}..."

    # Split window to create new pane
    tmux split-window -t "$RALPHS_SESSION:main" -h
    local new_pane
    new_pane=$(tmux display-message -t "$RALPHS_SESSION:main" -p '#{pane_index}')

    # Set pane title
    tmux select-pane -t "$RALPHS_SESSION:main.$new_pane" -T "$pane_name"

    # Change to worktree directory if in distributed mode
    if [[ -n "$worktree_path" ]]; then
        tmux send-keys -t "$RALPHS_SESSION:main.$new_pane" "cd '$worktree_path'" Enter
    fi

    # Run the agent command
    tmux send-keys -t "$RALPHS_SESSION:main.$new_pane" "# ralphs: $pane_name${ticket_id:+ ($ticket_id)}" Enter
    tmux send-keys -t "$RALPHS_SESSION:main.$new_pane" "$agent_cmd" Enter

    # Apply layout
    tmux select-layout -t "$RALPHS_SESSION:main" "$RALPHS_LAYOUT" 2>/dev/null || true

    # Register the pane
    register_pane "$pane_name" "$role" "$ticket_id"

    # Update ticket state if claiming
    if [[ -n "$ticket_id" ]] && [[ "$role" == "impl" || "$role" == "implementer" ]]; then
        local current_state
    current_state=$(get_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "state")
        if [[ "$current_state" == "ready" ]]; then
            set_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "state" "claimed"
            set_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "assigned_pane" "$pane_name"
            set_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "assigned_at" "$(timestamp)"
            run_hook "on-claim" "$ticket_id"
        fi
    fi

    # Show success message only when interactive (TTY)
    if [[ -t 1 ]]; then
        success "Spawned $pane_name"
    fi
    echo "$pane_name"
}

# List active panes
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

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit $EXIT_SESSION_NOT_FOUND
    fi

    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"

    case "$format" in
        json)
            if [[ -f "$registry" ]]; then
                cat "$registry"
            else
                echo "[]"
            fi
            ;;
        ids)
            if [[ -f "$registry" ]]; then
                grep -o '"pane": "[^"]*"' "$registry" | cut -d'"' -f4
            fi
            ;;
        table|*)
            echo ""
            printf "${BOLD}%-12s %-12s %-12s %-10s${NC}\n" "PANE" "ROLE" "TICKET" "UPTIME"
            echo "------------------------------------------------"

            if [[ -f "$registry" ]]; then
                # Parse each entry (simple approach)
                while IFS= read -r line; do
                    local pane
    pane=$(echo "$line" | grep -o '"pane": "[^"]*"' | cut -d'"' -f4)
                    local role
    role=$(echo "$line" | grep -o '"role": "[^"]*"' | cut -d'"' -f4)
                    local ticket
    ticket=$(echo "$line" | grep -o '"ticket": "[^"]*"' | cut -d'"' -f4)
                    local started
    started=$(echo "$line" | grep -o '"started_at": "[^"]*"' | cut -d'"' -f4)

                    [[ -z "$pane" ]] && continue

                    local uptime
    uptime=$(duration_since "$started")
                    printf "%-12s %-12s %-12s %-10s\n" "$pane" "$role" "${ticket:-—}" "$uptime"
                done < <(cat "$registry" | tr ',' '\n')
            fi
            echo ""
            ;;
    esac
}

# Kill a worker pane
cmd_kill() {
    if [[ $# -lt 1 ]]; then
        error "Usage: ralphs kill <pane-id> [--release-ticket]"
        exit $EXIT_INVALID_ARGS
    fi

    local pane_id="$1"
    shift
    local release_ticket=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --release-ticket|--release)
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

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit $EXIT_SESSION_NOT_FOUND
    fi

    # Find pane in registry
    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    local ticket_id=""

    if [[ -f "$registry" ]]; then
        local entry
    entry=$(grep "\"pane\": \"$pane_id\"" "$registry" || true)
        if [[ -n "$entry" ]]; then
            ticket_id=$(echo "$entry" | grep -o '"ticket": "[^"]*"' | cut -d'"' -f4)
        fi
    fi

    # Find and kill the tmux pane by title
    local panes
    panes=$(tmux list-panes -t "$RALPHS_SESSION:main" -F '#{pane_index} #{pane_title}' 2>/dev/null)
    local target_pane=""

    while IFS= read -r line; do
        local idx
    idx=$(echo "$line" | awk '{print $1}')
        local title
    title=$(echo "$line" | awk '{print $2}')
        if [[ "$title" == "$pane_id" ]]; then
            target_pane="$idx"
            break
        fi
    done <<< "$panes"

    if [[ -n "$target_pane" ]]; then
        tmux kill-pane -t "$RALPHS_SESSION:main.$target_pane"
        info "Killed tmux pane"
    fi

    # Unregister
    unregister_pane "$pane_id"

    # Release ticket if requested
    if [[ "$release_ticket" == "true" ]] && [[ -n "$ticket_id" ]]; then
        set_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "state" "ready"
        set_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "assigned_pane" ""
        info "Released ticket $ticket_id"
    fi

    success "Killed $pane_id"
}

# Send a message to a worker pane
cmd_ping() {
    if [[ $# -lt 2 ]]; then
        error "Usage: ralphs ping <pane-id> <message>"
        exit $EXIT_INVALID_ARGS
    fi

    local pane_id="$1"
    shift
    local message="$*"

    require_project
    load_config

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit $EXIT_SESSION_NOT_FOUND
    fi

    # Find pane by title
    local panes
    panes=$(tmux list-panes -t "$RALPHS_SESSION:main" -F '#{pane_index} #{pane_title}' 2>/dev/null)
    local target_pane=""

    while IFS= read -r line; do
        local idx
    idx=$(echo "$line" | awk '{print $1}')
        local title
    title=$(echo "$line" | awk '{print $2}')
        if [[ "$title" == "$pane_id" ]]; then
            target_pane="$idx"
            break
        fi
    done <<< "$panes"

    if [[ -z "$target_pane" ]]; then
        # Try direct index
        target_pane="$pane_id"
    fi

    # Send the message
    tmux send-keys -t "$RALPHS_SESSION:main.$target_pane" "# $message" Enter

    success "Pinged $pane_id"
}

# Check if there's capacity for more workers
cmd_has_capacity() {
    require_project
    load_config

    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    local current=0

    if [[ -f "$registry" ]]; then
        current=$(grep -c '"pane":' "$registry" 2>/dev/null || echo 0)
        # Subtract 1 for supervisor
        current=$((current > 0 ? current - 1 : 0))
    fi

    if [[ $current -lt $RALPHS_MAX_WORKERS ]]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}
