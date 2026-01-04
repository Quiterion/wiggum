#!/bin/bash
#
# tools.sh - Observability and summarization tools
#
# Following the WebFetch analogy: tools return insights, not raw data.
# They invoke ephemeral agents internally to process and summarize.
#

# Get overall status of the hive
cmd_status() {
    local verbose=false
    local format="table"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                verbose=true
                shift
                ;;
            --format)
                format="$2"
                shift 2
                ;;
            --format=*)
                format="${1#*=}"
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    require_project
    load_config

    # Tmux status bar format: compact one-liner
    if [[ "$format" == "tmux" ]]; then
        local agent_count=0
        local ready_count=0
        local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"

        if [[ -f "$registry" ]] && command -v jq &>/dev/null; then
            agent_count=$(jq 'length' "$registry" 2>/dev/null || echo 0)
        fi

        for ticket_file in $(bare_list_tickets); do
            local s
            s=$(bare_get_frontmatter_value "$ticket_file" "state" 2>/dev/null)
            [[ "$s" == "ready" ]] && ready_count=$((ready_count + 1))
        done

        echo "#[fg=green]${agent_count}#[default] #[fg=yellow]${ready_count}#[default]"
        return
    fi

    echo ""
    echo -e "${BOLD}SESSION:${NC} $WIGGUM_SESSION"

    if ! session_exists "$WIGGUM_SESSION"; then
        echo "  (not running)"
        echo ""
        return
    fi

    local pane_count
    pane_count=$(tmux list-panes -t "$WIGGUM_SESSION:main" 2>/dev/null | wc -l)
    echo "  Panes: $pane_count"
    echo ""

    # Show agents
    echo -e "${BOLD}AGENTS:${NC}"
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ -f "$registry" ]] && [[ -s "$registry" ]] && command -v jq &>/dev/null; then
        local keys
        keys=$(jq -r 'keys[]' "$registry" 2>/dev/null)
        if [[ -n "$keys" ]]; then
            for agent_id in $keys; do
                local role started uptime ticket state
                role=$(jq -r --arg id "$agent_id" '.[$id].role' "$registry")
                started=$(jq -r --arg id "$agent_id" '.[$id].started_at' "$registry")
                uptime=$(duration_since "$started")

                # Get ticket from tickets (single source of truth)
                ticket=$(get_agent_ticket "$agent_id")

                # Get ticket state if available (from bare repo)
                state=""
                if [[ -n "$ticket" ]]; then
                    state=$(bare_get_frontmatter_value "${ticket}.md" "state" 2>/dev/null)
                fi

                printf "  %-12s %-12s %-12s %-10s\n" "$agent_id" "${ticket:-—}" "${state:-—}" "$uptime"
            done
        else
            echo "  (no agents)"
        fi
    elif [[ -f "$registry" ]]; then
        echo "  (install jq for agent status)"
    else
        echo "  (no agents)"
    fi
    echo ""

    # Show ticket summary (from bare repo)
    echo -e "${BOLD}TICKETS:${NC}"
    for state in ready in-progress review qa "done"; do
        local count=0
        for ticket_file in $(bare_list_tickets); do
            local s
            s=$(bare_get_frontmatter_value "$ticket_file" "state")
            [[ "$s" == "$state" ]] && count=$((count + 1))
        done
        printf "  %-12s %d\n" "$state:" "$count"
    done
    echo ""

    if [[ "$verbose" == "true" ]]; then
        echo -e "${BOLD}READY TICKETS:${NC}"
        ticket_ready | while read -r id; do
            local title
            title=$(bare_read_ticket "${id}.md" | grep -m1 '^# ' | sed 's/^# //')
            echo "  $id: $title"
        done
        echo ""
    fi
}

# Fetch summarized progress from an agent
cmd_fetch() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum fetch <agent-id> [prompt]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local agent_id="$1"
    shift
    local prompt="${*:-Summarize the current progress and any blockers.}"

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

    # Capture pane output
    local pane_output
    pane_output=$(tmux capture-pane -t "$tmux_pane_id" -p -S -100 2>/dev/null)

    # Get ticket info from tickets (single source of truth)
    local ticket_id
    local ticket_content=""

    ticket_id=$(get_agent_ticket "$agent_id")

    if [[ -n "$ticket_id" ]]; then
        ticket_content=$(bare_read_ticket "${ticket_id}.md" 2>/dev/null)
    fi

    # Build context for ephemeral agent
    local context="
# Worker Pane Output (last 100 lines)

\`\`\`
$pane_output
\`\`\`
"

    if [[ -n "$ticket_content" ]]; then
        context="$context

# Assigned Ticket

$ticket_content
"
    fi

    context="$context

# Task

$prompt

Provide a concise summary (2-3 sentences max). Focus on:
- What has been accomplished
- Current status
- Any blockers or concerns
"

    # Invoke ephemeral agent
    if command -v "$WIGGUM_AGENT_CMD" &>/dev/null; then
        echo "$context" | "$WIGGUM_AGENT_CMD" --print 2>/dev/null || echo "$context"
    else
        # Fallback: just show recent activity indicator
        local lines
    lines=$(echo "$pane_output" | wc -l)
        local last_line
    last_line=$(echo "$pane_output" | tail -1)
        echo "Agent $agent_id: $lines lines of output"
        echo "Last activity: $last_line"
        if [[ -n "$ticket_id" ]]; then
            local state
            state=$(bare_get_frontmatter_value "${ticket_id}.md" "state" 2>/dev/null)
            echo "Ticket $ticket_id in state: $state"
        fi
    fi
}

# Summarize the whole hive
cmd_digest() {
    local prompt="${*:-Provide an overview of the hive status.}"

    require_project
    load_config

    if ! session_exists "$WIGGUM_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Build context
    local context="# Hive Status

"

    # Add agent summaries
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ -f "$registry" ]] && [[ -s "$registry" ]] && command -v jq &>/dev/null; then
        local keys
        keys=$(jq -r 'keys[]' "$registry" 2>/dev/null)
        if [[ -n "$keys" ]]; then
            context="$context## Active Agents

"
            for agent_id in $keys; do
                local role ticket title
                role=$(jq -r --arg id "$agent_id" '.[$id].role' "$registry")
                # Get ticket from tickets (single source of truth)
                ticket=$(get_agent_ticket "$agent_id")

                context="$context- $agent_id ($role)"
                if [[ -n "$ticket" ]]; then
                    title=$(bare_read_ticket "${ticket}.md" 2>/dev/null | grep -m1 '^# ' | sed 's/^# //')
                    context="$context: $ticket - $title"
                fi
                context="$context
"
            done
        fi
    fi

    # Add ticket summary
    context="$context
## Ticket States

"
    for state in ready claimed implement review qa "done"; do
        local count=0
        for ticket_file in $(bare_list_tickets); do
            local s
            s=$(bare_get_frontmatter_value "$ticket_file" "state")
            [[ "$s" == "$state" ]] && count=$((count + 1))
        done
        context="$context- $state: $count
"
    done

    context="$context
# Task

$prompt

Provide a brief executive summary.
"

    # Invoke ephemeral agent or fallback
    if command -v "$WIGGUM_AGENT_CMD" &>/dev/null; then
        echo "$context" | "$WIGGUM_AGENT_CMD" --print 2>/dev/null || echo "$context"
    else
        # Fallback: show raw context
        echo "$context"
    fi
}

# Show raw agent pane logs
cmd_logs() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum logs <agent-id> [--tail N] [--follow]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local agent_id="$1"
    shift
    local tail_lines=50
    local follow=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tail)
                tail_lines="$2"
                shift 2
                ;;
            --follow|-f)
                follow=true
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

    # Look up tmux pane ID from registry
    local tmux_pane_id
    tmux_pane_id=$(get_tmux_pane_id "$agent_id")

    if [[ -z "$tmux_pane_id" ]]; then
        error "Agent not found in registry: $agent_id"
        exit "$EXIT_PANE_NOT_FOUND"
    fi

    if [[ "$follow" == "true" ]]; then
        # Attach in view mode
        tmux capture-pane -t "$tmux_pane_id" -p -S -"$tail_lines"
        echo "---"
        echo "(Following... Ctrl+C to exit)"
        while true; do
            sleep 1
            tmux capture-pane -t "$tmux_pane_id" -p -S -1 2>/dev/null || break
        done
    else
        tmux capture-pane -t "$tmux_pane_id" -p -S -"$tail_lines"
    fi
}

# Build context for an agent about to work on a ticket
cmd_context() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum context <ticket-id> [prompt]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    shift
    local prompt="${*:-Provide a full briefing for working on this ticket.}"

    require_project

    # Read ticket from bare repo (source of truth)
    local ticket_content
    ticket_content=$(bare_read_ticket "${id}.md")

    # Build context
    local context
    context="# Ticket Briefing: $id

## Ticket Content

$ticket_content

"

    # Add dependency info
    local deps
    deps=$(echo "$ticket_content" | awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}')
    if [[ -n "$deps" ]]; then
        context="$context## Dependencies

"
        for dep in $deps; do
            [[ -z "$dep" ]] && continue
            local dep_content
            dep_content=$(bare_read_ticket "${dep}.md" 2>/dev/null)
            if [[ -n "$dep_content" ]]; then
                local dep_state
                dep_state=$(echo "$dep_content" | awk '/^state:/{print $2; exit}')
                local dep_title
                dep_title=$(echo "$dep_content" | grep -m1 '^# ' | sed 's/^# //')
                context="$context- $dep [$dep_state]: $dep_title
"
            fi
        done
        context="$context
"
    fi

    # Look for related specs
    if [[ -d "$MAIN_PROJECT_ROOT/specs" ]]; then
        local title
    title=$(grep -m1 '^# ' "$ticket_path" | sed 's/^# //' | tr '[:upper:]' '[:lower:]')
        local related_specs=""

        for spec_file in "$MAIN_PROJECT_ROOT/specs"/*.md "$MAIN_PROJECT_ROOT/specs"/**/*.md; do
            [[ -f "$spec_file" ]] || continue
            # Simple keyword matching
            if grep -qi "$title" "$spec_file" 2>/dev/null; then
                related_specs="$related_specs
- $(basename "$spec_file")"
            fi
        done

        if [[ -n "$related_specs" ]]; then
            context="$context## Related Specs
$related_specs

"
        fi
    fi

    context="$context# Task

$prompt
"

    # Output or process
    if command -v "$WIGGUM_AGENT_CMD" &>/dev/null && [[ "$prompt" != "Provide a full briefing for working on this ticket." ]]; then
        echo "$context" | "$WIGGUM_AGENT_CMD" --print 2>/dev/null || echo "$context"
    else
        echo "$context"
    fi
}

# Run an ephemeral agent (internal use)
cmd_ephemeral() {
    local prompt=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prompt)
                prompt="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    load_config

    # Read from stdin, apply prompt, output result
    local input
    input=$(cat)

    if command -v "$WIGGUM_AGENT_CMD" &>/dev/null; then
        echo -e "$prompt\n\n$input" | "$WIGGUM_AGENT_CMD" --print 2>/dev/null
    else
        echo "$input"
    fi
}
