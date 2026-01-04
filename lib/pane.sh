#!/bin/bash
#
# pane.sh - tmux pane management
#

# Track pane assignments in a file
PANE_REGISTRY_FILE=".ralphs/panes.json"

# Send input to a pane, handling editor mode (vim/emacs keybinds)
# Usage: send_pane_input <session:window.pane> <message>
# Respects RALPHS_EDITOR_MODE config: "normal" (default), "vim", "emacs"
send_pane_input() {
    local target="$1"
    local message="$2"

    if [[ "${RALPHS_EDITOR_MODE:-normal}" == "vim" ]]; then
        # Vim mode: Escape to ensure normal mode, 'i' to insert, type message, Enter to submit
        tmux send-keys -t "$target" Escape
        sleep 0.2
        tmux send-keys -t "$target" "i"
        sleep 0.2
        # Send message as literal text, then Enter to submit
        tmux send-keys -t "$target" -l "$message"
        tmux send-keys -t "$target" Enter
    else
        # Normal mode: just send message and Enter
        tmux send-keys -t "$target" -l "$message"
        tmux send-keys -t "$target" Enter
    fi
}

# Get next pane index for a role
get_next_pane_index() {
    local role="$1"
    require_project

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ ! -f "$registry" ]]; then
        echo "0"
        return
    fi

    # Count existing panes with this role
    # Note: grep -c outputs "0" and exits with 1 when no matches, so we use || true
    # to suppress the exit code without adding extra output
    local count
    count=$(grep -c "\"role\": \"$role\"" "$registry" 2>/dev/null || true)
    # Ensure we have a valid number
    [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]] && count=0
    echo "$count"
}

# Register a pane
register_pane() {
    local pane_id="$1"
    local role="$2"
    local ticket_id="${3:-}"

    require_project
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"

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

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
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
    elif [[ -f "$RALPHS_DEFAULTS/prompts/${role}.md" ]]; then
        template=$(cat "$RALPHS_DEFAULTS/prompts/${role}.md")
    else
        # No template found, return minimal prompt
        if [[ -n "$ticket_id" ]]; then
            echo "You are a $role agent. Your ticket is $ticket_id. Read the ticket at .ralphs/tickets/${ticket_id}.md and complete the work described."
        else
            echo "You are a $role agent for the ralphs multi-agent system."
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
    if [[ "$role" == "supervisor" ]] && [[ -d "$PROJECT_ROOT/specs" ]]; then
        project_specs=$(find "$PROJECT_ROOT/specs" -name "*.md" -exec basename {} \; 2>/dev/null | head -20 | tr '\n' ', ')
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
        error "Usage: ralphs spawn <role> [ticket-id] [--prompt PATH]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local role="$1"
    shift

    local ticket_id="${1:-}"
    [[ "$ticket_id" == --* ]] && ticket_id=""  # Handle flags

    require_project
    load_config
    require_command tmux

    # Create session if it doesn't exist
    if ! session_exists "$RALPHS_SESSION"; then
        info "Creating tmux session: $RALPHS_SESSION"
        tmux new-session -d -s "$RALPHS_SESSION" -n "main"
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

    # Build pane name
    local pane_index
    pane_index=$(get_next_pane_index "$role")
    # Strip any whitespace/newlines that might have crept in
    pane_index="${pane_index//[$'\t\r\n ']/}"
    local pane_name="${role}-${pane_index}"

    # Build the agent command
    local agent_cmd="$RALPHS_AGENT_CMD"

    # Create a worktree for the agent
    local worktree_path="$PROJECT_ROOT/worktrees/$pane_name"
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
        # shellcheck disable=SC2015
        [[ -d "$RALPHS_DIR/hooks" ]] && cp -r "$RALPHS_DIR/hooks/"* "$worktree_path/.ralphs/hooks/" 2>/dev/null || true
        # shellcheck disable=SC2015
        [[ -d "$RALPHS_DIR/prompts" ]] && cp -r "$RALPHS_DIR/prompts/"* "$worktree_path/.ralphs/prompts/" 2>/dev/null || true
    fi

    # Create new pane
    info "Spawning $pane_name${ticket_id:+ for $ticket_id}..."

    # Split window to create new pane
    tmux split-window -t "$RALPHS_SESSION:main" -h
    local new_pane
    new_pane=$(tmux display-message -t "$RALPHS_SESSION:main" -p '#{pane_index}')

    # Set pane title
    tmux select-pane -t "$RALPHS_SESSION:main.$new_pane" -T "$pane_name"

    # Change to worktree directory
    tmux send-keys -t "$RALPHS_SESSION:main.$new_pane" "cd '$worktree_path'" Enter

    # Build the agent prompt
    local prompt
    prompt=$(build_agent_prompt "$role" "$ticket_id" "$worktree_path")

    # Write prompt to a file in the worktree for the agent to read
    local prompt_file="$worktree_path/.ralphs/current_prompt.md"
    echo "$prompt" > "$prompt_file"

    # Start the agent
    tmux send-keys -t "$RALPHS_SESSION:main.$new_pane" "$agent_cmd" Enter

    # Wait for agent to initialize (give it time to show welcome banner)
    sleep 2

    # Send the initial prompt using vim-safe input
    local initial_msg="Please read your role instructions from .ralphs/current_prompt.md and begin your work. Your role is: $role${ticket_id:+, assigned ticket: $ticket_id}"
    send_pane_input "$RALPHS_SESSION:main.$new_pane" "$initial_msg"

    # Apply layout
    tmux select-layout -t "$RALPHS_SESSION:main" "$RALPHS_LAYOUT" 2>/dev/null || true

    # Register the pane
    register_pane "$pane_name" "$role" "$ticket_id"

    # Start work on ticket if it's ready (assigning a ticket to any agent starts it)
    if [[ -n "$ticket_id" ]]; then
        local current_state
        current_state=$(get_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "state")
        if [[ "$current_state" == "ready" ]]; then
            set_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "state" "in-progress"
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
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"

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

            if [[ -f "$registry" ]] && command -v jq &>/dev/null; then
                # Use jq for proper JSON parsing
                local count
                count=$(jq 'length' "$registry")
                for ((i=0; i<count; i++)); do
                    local pane role ticket started uptime
                    pane=$(jq -r ".[$i].pane" "$registry")
                    role=$(jq -r ".[$i].role" "$registry")
                    ticket=$(jq -r ".[$i].ticket // empty" "$registry")
                    started=$(jq -r ".[$i].started_at" "$registry")
                    uptime=$(duration_since "$started")
                    printf "%-12s %-12s %-12s %-10s\n" "$pane" "$role" "${ticket:-—}" "$uptime"
                done
            elif [[ -f "$registry" ]]; then
                # Fallback: parse JSON without jq (less reliable)
                warn "jq not found, using basic parsing"
                # Extract each object by matching balanced braces
                local content
                content=$(cat "$registry")
                while [[ "$content" =~ \{([^}]+)\} ]]; do
                    local obj="${BASH_REMATCH[1]}"
                    local pane role ticket started uptime
                    pane=$(echo "$obj" | grep -o '"pane"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
                    role=$(echo "$obj" | grep -o '"role"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
                    ticket=$(echo "$obj" | grep -o '"ticket"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
                    started=$(echo "$obj" | grep -o '"started_at"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
                    if [[ -n "$pane" ]]; then
                        uptime=$(duration_since "$started")
                        printf "%-12s %-12s %-12s %-10s\n" "$pane" "$role" "${ticket:-—}" "$uptime"
                    fi
                    # Remove processed object from content
                    content="${content#*\}}"
                done
            fi
            echo ""
            ;;
    esac
}

# Kill a worker pane
cmd_kill() {
    if [[ $# -lt 1 ]]; then
        error "Usage: ralphs kill <pane-id> [--release-ticket]"
        exit "$EXIT_INVALID_ARGS"
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
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Find pane in registry
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
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
        exit "$EXIT_INVALID_ARGS"
    fi

    local pane_id="$1"
    shift
    local message="$*"

    require_project
    load_config

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
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

    # Send the message using vim-safe input
    send_pane_input "$RALPHS_SESSION:main.$target_pane" "$message"

    success "Pinged $pane_id"
}

# Check if there's capacity for more workers
cmd_has_capacity() {
    require_project
    load_config

    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    local current=0

    if [[ -f "$registry" ]]; then
        current=$(grep -c '"pane":' "$registry" 2>/dev/null || echo 0)
        # Subtract 1 for supervisor
        current=$((current > 0 ? current - 1 : 0))
    fi

    if [[ $current -lt $RALPHS_MAX_AGENTS ]]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}
