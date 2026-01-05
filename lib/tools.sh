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
            agent_count=$(jq 'length' "$registry" || echo 0)
        fi

        for ticket_file in $(bare_list_tickets); do
            local s
            s=$(bare_get_frontmatter_value "$ticket_file" "state")
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
    pane_count=$(tmux list-panes -t "$WIGGUM_SESSION:main" | wc -l)
    echo "  Panes: $pane_count"
    echo ""

    # Show agents
    echo -e "${BOLD}AGENTS:${NC}"
    local registry="$MAIN_PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ -f "$registry" ]] && [[ -s "$registry" ]] && command -v jq &>/dev/null; then
        local keys
        keys=$(jq -r 'keys[]' "$registry")
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
                    state=$(bare_get_frontmatter_value "${ticket}.md" "state")
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
    local prompt="${*:-Summarize TARGET_AGENT progress against the ticket acceptance criteria. Output sections: Accomplished, Current status, Blockers (with evidence + 1–2 unblocking options each), Next actions (max 3), Waiting for input? (yes/no). Cite concrete evidence from the last N trajectory lines. Label any inference and give confidence.}"

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
    pane_output=$(tmux capture-pane -t "$tmux_pane_id" -p -S -100)

    # Get ticket info from tickets (single source of truth)
    local ticket_id
    local ticket_content=""

    ticket_id=$(get_agent_ticket "$agent_id")

    if [[ -n "$ticket_id" ]]; then
        ticket_content=$(bare_read_ticket "${ticket_id}.md")
    fi

    # Build context for ephemeral agent
    local context="
You are an ephemeral agent for information retrieval, invoked by the wiggum multi-agent orchestration system.

# Task

Your task is to synthesize the trajectory of the TARGET_AGENT into an answer to the following request.

<request>
"$prompt"
</request>

Please pay critical attention to the following when synthesizing your response:
- What has been accomplished
- Current status
- Any blockers or concerns
- Is the TARGET_AGENT waiting idly for input?

Respond in a maximum of 2 paragraphs.

# Context

TARGET_AGENT=\"$agent_id\"
"

    if [[ -n "$ticket_content" ]]; then
        context="$context
You may find it useful to note that the TARGET_AGENT is currently assigned to the following ticket:

=== BEGIN TARGET_AGENT TICKET CONTENT ===
<$agent_id-ticket-content>
\`\`\`
"$ticket_content"
\`\`\`
</$agent_id-ticket-content>
=== END TARGET_AGENT TICKET CONTENT ===
"
    fi

    context="$context
=== BEGIN TARGET_AGENT TRAJECTORY ===
<$agent_id-trajectory>
\`\`\`
"$pane_output"
\`\`\`
</$agent_id-trajectory>
=== END TARGET_AGENT TRAJECTORY ===
"

    fetch_fallback() {
        # Fallback: just show recent activity indicator
        local lines
        lines=$(echo "$pane_output" | wc -l)
        local last_line
        last_line=$(echo "$pane_output" | tail -1)
        warn "Failed to provide intelligent summary."
        echo "Agent $agent_id: $lines lines of output"
        echo "Last activity: $last_line"
        if [[ -n "$ticket_id" ]]; then
            local state
            state=$(bare_get_frontmatter_value "${ticket_id}.md" "state")
            echo "Ticket $ticket_id in state: $state"
        fi
    }

   cmd_ephemeral "$context" || fetch_fallback
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
        keys=$(jq -r 'keys[]' "$registry")
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
                    title=$(bare_read_ticket "${ticket}.md" | grep -m1 '^# ' | sed 's/^# //')
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
    cmd_ephemeral "$context" || echo "$context"
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
            tmux capture-pane -t "$tmux_pane_id" -p -S -1 || break
        done
    else
        tmux capture-pane -t "$tmux_pane_id" -p -S -"$tail_lines"
    fi
}

# Run an ephemeral agent (internal use)
cmd_ephemeral() {
    local prompt="${*}"
    load_config
    if [[ -z "$prompt" ]]; then
        error "No context provided to ephemeral agent"
    fi
    if command -v "$WIGGUM_AGENT_CMD" &>/dev/null; then
        "$WIGGUM_AGENT_CMD" --print -- "$prompt" || warn "Error invoking $WIGGUM_AGENT_CMD"
    else
        error '$WIGGUM_AGENT_CMD is unset or does not exist'
    fi
}
