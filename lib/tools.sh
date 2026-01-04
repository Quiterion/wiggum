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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose|-v)
                verbose=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    require_project
    load_config

    echo ""
    echo "${BOLD}SESSION:${NC} $RALPHS_SESSION"

    if ! session_exists "$RALPHS_SESSION"; then
        echo "  (not running)"
        echo ""
        return
    fi

    local pane_count
    pane_count=$(tmux list-panes -t "$RALPHS_SESSION:main" 2>/dev/null | wc -l)
    echo "  Panes: $pane_count"
    echo ""

    # Show workers
    echo "${BOLD}WORKERS:${NC}"
    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ -f "$registry" ]] && [[ -s "$registry" ]] && [[ "$(cat "$registry")" != "[]" ]]; then
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

            # Get ticket state if available
            local state=""
            if [[ -n "$ticket" ]] && [[ -f "$TICKETS_DIR/${ticket}.md" ]]; then
                state=$(get_frontmatter_value "$TICKETS_DIR/${ticket}.md" "state")
            fi

            printf "  %-12s %-12s %-12s %-10s\n" "$pane" "${ticket:-—}" "${state:-—}" "$uptime"
        done < <(tr ',' '\n' < "$registry")
    else
        echo "  (no workers)"
    fi
    echo ""

    # Show ticket summary
    echo "${BOLD}TICKETS:${NC}"
    for state in ready claimed implement review qa "done"; do
        local count=0
        for ticket_file in "$TICKETS_DIR"/*.md; do
            [[ -f "$ticket_file" ]] || continue
            local s
    s=$(get_frontmatter_value "$ticket_file" "state")
            [[ "$s" == "$state" ]] && count=$((count + 1))
        done
        printf "  %-12s %d\n" "$state:" "$count"
    done
    echo ""

    if [[ "$verbose" == "true" ]]; then
        echo "${BOLD}READY TICKETS:${NC}"
        ticket_ready | while read -r id; do
            local title
    title=$(grep -m1 '^# ' "$TICKETS_DIR/${id}.md" | sed 's/^# //')
            echo "  $id: $title"
        done
        echo ""
    fi
}

# Fetch summarized progress from a worker
cmd_fetch() {
    if [[ $# -lt 1 ]]; then
        error "Usage: ralphs fetch <pane-id> [prompt]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local pane_id="$1"
    shift
    local prompt="${*:-Summarize the current progress and any blockers.}"

    require_project
    load_config

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Find pane by title or index
    local target_pane=""
    local panes
    panes=$(tmux list-panes -t "$RALPHS_SESSION:main" -F '#{pane_index} #{pane_title}' 2>/dev/null)

    while IFS= read -r line; do
        local idx
    idx=$(echo "$line" | awk '{print $1}')
        local title
    title=$(echo "$line" | awk '{print $2}')
        if [[ "$title" == "$pane_id" ]] || [[ "$idx" == "$pane_id" ]]; then
            target_pane="$idx"
            break
        fi
    done <<< "$panes"

    if [[ -z "$target_pane" ]]; then
        error "Pane not found: $pane_id"
        exit "$EXIT_PANE_NOT_FOUND"
    fi

    # Capture pane output
    local pane_output
    pane_output=$(tmux capture-pane -t "$RALPHS_SESSION:main.$target_pane" -p -S -100 2>/dev/null)

    # Get ticket info if available
    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    local ticket_id=""
    local ticket_content=""

    if [[ -f "$registry" ]]; then
        local entry
    entry=$(grep "\"pane\": \"$pane_id\"" "$registry" || true)
        if [[ -n "$entry" ]]; then
            ticket_id=$(echo "$entry" | grep -o '"ticket": "[^"]*"' | cut -d'"' -f4)
        fi
    fi

    if [[ -n "$ticket_id" ]] && [[ -f "$TICKETS_DIR/${ticket_id}.md" ]]; then
        ticket_content=$(<"$TICKETS_DIR/${ticket_id}.md")
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
    if command -v "$RALPHS_AGENT_CMD" &>/dev/null; then
        echo "$context" | "$RALPHS_AGENT_CMD" --print 2>/dev/null || echo "$context"
    else
        # Fallback: just show recent activity indicator
        local lines
    lines=$(echo "$pane_output" | wc -l)
        local last_line
    last_line=$(echo "$pane_output" | tail -1)
        echo "Pane $pane_id: $lines lines of output"
        echo "Last activity: $last_line"
        if [[ -n "$ticket_id" ]]; then
            local state
    state=$(get_frontmatter_value "$TICKETS_DIR/${ticket_id}.md" "state")
            echo "Ticket $ticket_id in state: $state"
        fi
    fi
}

# Summarize the whole hive
cmd_digest() {
    local prompt="${*:-Provide an overview of the hive status.}"

    require_project
    load_config

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Build context
    local context="# Hive Status

"

    # Add worker summaries
    local registry="$PROJECT_ROOT/$PANE_REGISTRY_FILE"
    if [[ -f "$registry" ]] && [[ -s "$registry" ]]; then
        context="$context## Active Workers

"
        while IFS= read -r line; do
            local pane
    pane=$(echo "$line" | grep -o '"pane": "[^"]*"' | cut -d'"' -f4)
            local role
    role=$(echo "$line" | grep -o '"role": "[^"]*"' | cut -d'"' -f4)
            local ticket
    ticket=$(echo "$line" | grep -o '"ticket": "[^"]*"' | cut -d'"' -f4)

            [[ -z "$pane" ]] && continue

            context="$context- $pane ($role)"
            if [[ -n "$ticket" ]]; then
                local title
    title=$(grep -m1 '^# ' "$TICKETS_DIR/${ticket}.md" 2>/dev/null | sed 's/^# //')
                context="$context: $ticket - $title"
            fi
            context="$context
"
        done < <(tr ',' '\n' < "$registry")
    fi

    # Add ticket summary
    context="$context
## Ticket States

"
    for state in ready claimed implement review qa "done"; do
        local count=0
        for ticket_file in "$TICKETS_DIR"/*.md; do
            [[ -f "$ticket_file" ]] || continue
            local s
    s=$(get_frontmatter_value "$ticket_file" "state")
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
    if command -v "$RALPHS_AGENT_CMD" &>/dev/null; then
        echo "$context" | "$RALPHS_AGENT_CMD" --print 2>/dev/null || echo "$context"
    else
        # Fallback: show raw context
        echo "$context"
    fi
}

# Show raw pane logs
cmd_logs() {
    if [[ $# -lt 1 ]]; then
        error "Usage: ralphs logs <pane-id> [--tail N] [--follow]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local pane_id="$1"
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

    if ! session_exists "$RALPHS_SESSION"; then
        error "Session not found"
        exit "$EXIT_SESSION_NOT_FOUND"
    fi

    # Find pane
    local target_pane=""
    local panes
    panes=$(tmux list-panes -t "$RALPHS_SESSION:main" -F '#{pane_index} #{pane_title}' 2>/dev/null)

    while IFS= read -r line; do
        local idx
    idx=$(echo "$line" | awk '{print $1}')
        local title
    title=$(echo "$line" | awk '{print $2}')
        if [[ "$title" == "$pane_id" ]] || [[ "$idx" == "$pane_id" ]]; then
            target_pane="$idx"
            break
        fi
    done <<< "$panes"

    if [[ -z "$target_pane" ]]; then
        error "Pane not found: $pane_id"
        exit "$EXIT_PANE_NOT_FOUND"
    fi

    if [[ "$follow" == "true" ]]; then
        # Attach in view mode
        tmux capture-pane -t "$RALPHS_SESSION:main.$target_pane" -p -S -"$tail_lines"
        echo "---"
        echo "(Following... Ctrl+C to exit)"
        while true; do
            sleep 1
            tmux capture-pane -t "$RALPHS_SESSION:main.$target_pane" -p -S -1 2>/dev/null || break
        done
    else
        tmux capture-pane -t "$RALPHS_SESSION:main.$target_pane" -p -S -"$tail_lines"
    fi
}

# Build context for an agent about to work on a ticket
cmd_context() {
    if [[ $# -lt 1 ]]; then
        error "Usage: ralphs context <ticket-id> [prompt]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    shift
    local prompt="${*:-Provide a full briefing for working on this ticket.}"

    require_project

    local ticket_path="$TICKETS_DIR/${id}.md"

    # Build context
    local context
    context="# Ticket Briefing: $id

## Ticket Content

$(<"$ticket_path")

"

    # Add dependency info
    local deps
    deps=$(awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}' "$ticket_path")
    if [[ -n "$deps" ]]; then
        context="$context## Dependencies

"
        for dep in $deps; do
            [[ -z "$dep" ]] && continue
            if [[ -f "$TICKETS_DIR/${dep}.md" ]]; then
                local dep_state
    dep_state=$(get_frontmatter_value "$TICKETS_DIR/${dep}.md" "state")
                local dep_title
    dep_title=$(grep -m1 '^# ' "$TICKETS_DIR/${dep}.md" | sed 's/^# //')
                context="$context- $dep [$dep_state]: $dep_title
"
            fi
        done
        context="$context
"
    fi

    # Look for related specs
    if [[ -d "$PROJECT_ROOT/specs" ]]; then
        local title
    title=$(grep -m1 '^# ' "$ticket_path" | sed 's/^# //' | tr '[:upper:]' '[:lower:]')
        local related_specs=""

        for spec_file in "$PROJECT_ROOT/specs"/*.md "$PROJECT_ROOT/specs"/**/*.md; do
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
    if command -v "$RALPHS_AGENT_CMD" &>/dev/null && [[ "$prompt" != "Provide a full briefing for working on this ticket." ]]; then
        echo "$context" | "$RALPHS_AGENT_CMD" --print 2>/dev/null || echo "$context"
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

    if command -v "$RALPHS_AGENT_CMD" &>/dev/null; then
        echo -e "$prompt\n\n$input" | "$RALPHS_AGENT_CMD" --print 2>/dev/null
    else
        echo "$input"
    fi
}
