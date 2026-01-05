#!/bin/bash
#
# ticket.sh - Ticket management system
#
# Supports both bare repo (main project) and clone (agent worktrees)
#

# Valid states and transitions
VALID_STATES=("ready" "in-progress" "review" "qa" "done" "closed")

#
# Ticket I/O abstraction layer
# Works with both bare repo and clone
#

# Check if we're using a clone (vs bare repo)
has_ticket_clone() {
    [[ -d "$TICKETS_DIR/.git" ]]
}

# Read ticket content
read_ticket() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket show <id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    require_project

    # Sync before read operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    local ticket_path="$TICKETS_DIR/${id}.md"
    if [[ ! -f "$ticket_path" ]]; then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi

    cat "$ticket_path"
}

# Write ticket content
write_ticket() {
    local id="$1"
    local content="$2"
    local commit_msg="${3:-Update ticket: $id}"

    ticket_sync_pull || error "Failed to pull ticket changes"
    echo "$content" >"$TICKETS_DIR/${id}.md"
    ticket_sync_push "$commit_msg" || error "Failed to push ticket changes"
}

# Get frontmatter value from ticket (works with both modes)
get_ticket_value() {
    local id="$1"
    local key="$2"
    local content
    content=$(read_ticket "$id")
    echo "$content" | awk -F': ' "/^${key}:/{print \$2; exit}"
}

# Set frontmatter value in ticket (works with both modes)
set_ticket_value() {
    local id="$1"
    local key="$2"
    local value="$3"
    local commit_msg="${4:-Update $key on $id}"

    local content
    content=$(read_ticket "$id")
    local updated
    updated=$(echo "$content" | awk -v key="$key" -v val="$value" '
        $0 ~ "^"key":" { print key": "val; next }
        { print }
    ')
    write_ticket "$id" "$updated" "$commit_msg"
}

# Look up ticket assigned to an agent by scanning tickets
# Usage: get_agent_ticket <agent-id>
# Returns: ticket ID or empty string if not assigned
get_agent_ticket() {
    local agent_id="$1"
    require_project

    # Sync before write operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    for ticket_file in "$TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue
        local assigned
        assigned=$(get_frontmatter_value "$ticket_file" "assigned_agent_id")
        if [[ "$assigned" == "$agent_id" ]]; then
            basename "$ticket_file" .md
            return
        fi
    done
}

# Check if ticket exists
ticket_exists() {
    local id="$1"
    ticket_sync_pull || error "Failed to pull ticket changes"
    [[ -f "$TICKETS_DIR/${id}.md" ]]
}

# Get ticket title (first H1)
get_ticket_title() {
    local id="$1"
    read_ticket "$id" | grep -m1 '^# ' | sed 's/^# //'
}

# Get ticket dependencies
get_ticket_deps() {
    local id="$1"
    read_ticket "$id" | awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}'
}

# State transition rules: from -> allowed targets
declare -A TRANSITIONS=(
    ["ready"]="in-progress closed"
    ["in-progress"]="review"
    ["review"]="qa in-progress done closed"
    ["qa"]="done in-progress closed"
)

# Ticket subcommand router
cmd_ticket() {
    if [[ $# -eq 0 ]]; then
        error "Usage: wiggum ticket <subcommand>"
        echo "Subcommands: create, list, show, ready, blocked, tree, transition, assign, unassign, edit, comment"
        exit "$EXIT_INVALID_ARGS"
    fi

    local subcmd="$1"
    shift

    case "$subcmd" in
        create)
            ticket_create "$@"
            ;;
        list)
            ticket_list "$@"
            ;;
        show)
            ticket_show "$@"
            ;;
        ready)
            ticket_ready "$@"
            ;;
        blocked)
            ticket_blocked "$@"
            ;;
        tree)
            ticket_tree "$@"
            ;;
        transition)
            ticket_transition "$@"
            ;;
        edit)
            ticket_edit "$@"
            ;;
        comment)
            ticket_comment "$@"
            ;;
        assign)
            ticket_assign "$@"
            ;;
        unassign)
            ticket_unassign "$@"
                ;;
        sync)
            cmd_ticket_sync "$@"
            ;;
        *)
            error "Unknown subcommand: $subcmd"
            exit "$EXIT_INVALID_ARGS"
            ;;
    esac
}

# Create a new ticket
ticket_create() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket create <title> [--type TYPE] [--priority N] [--dep ID] [--description TEXT] [--acceptance-test TEXT]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local title="$1"
    shift

    local type="task"
    local priority=2
    local deps=()
    local description=""
    local acceptance_tests=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --type)
            type="$2"
            shift 2
            ;;
        --priority)
            priority="$2"
            shift 2
            ;;
        --dep)
            deps+=("$2")
            shift 2
            ;;
        --description | -d)
            description="$2"
            shift 2
            ;;
        --acceptance-test)
            acceptance_tests+=("$2")
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project

    # Sync before write operation (only for clones)
    # shellcheck disable=SC2015
    has_ticket_clone && ticket_sync_pull || true

    # Generate ticket ID
    local id
    id=$(generate_id "tk")

    # Build dependencies YAML
    local deps_yaml=""
    if [[ ${#deps[@]} -gt 0 ]]; then
        deps_yaml="depends_on:"
        for dep in "${deps[@]}"; do
            deps_yaml+="\n  - $dep"
        done
    else
        deps_yaml="depends_on: []"
    fi

    # Determine initial state (ready if no deps, otherwise blocked implicitly)
    local state="ready"

    # Build description content
    local desc_content
    if [[ -n "$description" ]]; then
        desc_content="$description"
    else
        desc_content="[Add description here]"
    fi

    # Build acceptance criteria content
    local ac_content
    if [[ ${#acceptance_tests[@]} -gt 0 ]]; then
        ac_content=""
        for ac in "${acceptance_tests[@]}"; do
            ac_content+="- [ ] $ac"$'\n'
        done
        # Remove trailing newline
        ac_content="${ac_content%$'\n'}"
    else
        ac_content="- [ ] [Add criteria]"
    fi

    # Build ticket content
    local content
    content="---
id: $id
type: $type
priority: $priority
state: $state
assigned_agent_id:
assigned_at:
$(echo -e "$deps_yaml")
blocks: []
created_at: $(timestamp)
created_by: manual
---

# $title

## Description

$desc_content

## Acceptance Criteria

$ac_content

## Comments
"

    # Write ticket using abstraction
    write_ticket "$id" "$content" "Create ticket: $id"

    # Show success message only when interactive (TTY)
    if [[ -t 1 ]]; then
        success "Created ticket: $id"
    fi
    echo "$id"
}

# List tickets
ticket_list() {
    local filter_state=""
    local filter_type=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --state)
            filter_state="$2"
            shift 2
            ;;
        --type)
            filter_type="$2"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project

    # Sync before read operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    echo ""
    printf "${BOLD}%-10s %-10s %-10s %-3s %-40s${NC}\n" "ID" "STATE" "TYPE" "PRI" "TITLE"
    echo "-------------------------------------------------------------------------------"

    for ticket_file in "$TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue

        local id
        id=$(get_frontmatter_value "$ticket_file" "id")
        local state
        state=$(get_frontmatter_value "$ticket_file" "state")
        local type
        type=$(get_frontmatter_value "$ticket_file" "type")
        local priority
        priority=$(get_frontmatter_value "$ticket_file" "priority")

        # Apply filters
        if [[ -n "$filter_state" ]] && [[ "$state" != "$filter_state" ]]; then continue; fi
        if [[ -n "$filter_type" ]] && [[ "$type" != "$filter_type" ]]; then continue; fi

        # Get title (first H1)
        local title
        title=$(grep -m1 '^# ' "$ticket_file" | sed 's/^# //')

        # Truncate title if needed
        if [[ ${#title} -gt 38 ]]; then title="${title:0:35}..."; fi

        printf "%-10s %-10s %-10s %-3s %-40s\n" "$id" "$state" "$type" "$priority" "$title"
    done

    echo ""
}

# Show ticket details
ticket_show() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket show <id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    require_project

    # Sync before read operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    local ticket_path="$TICKETS_DIR/${id}.md"
    if [[ ! -f "$ticket_path" ]]; then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi

    cat "$ticket_path"
}

# List ready tickets (no unmet dependencies)
ticket_ready() {
    local limit=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --limit)
            limit="$2"
            shift 2
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project

    # Sync before read operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    local count=0
    for ticket_file in "$TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue

        local state
        state=$(get_frontmatter_value "$ticket_file" "state")
        if [[ "$state" != "ready" ]]; then continue; fi

        # Check dependencies
        local blocked=false
        local deps
        deps=$(awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}' "$ticket_file")

        for dep in $deps; do
            if [[ -z "$dep" ]]; then continue; fi
            local dep_file="$TICKETS_DIR/${dep}.md"
            if [[ -f "$dep_file" ]]; then
                local dep_state
                dep_state=$(get_frontmatter_value "$dep_file" "state")
                if [[ "$dep_state" != "done" ]]; then
                    blocked=true
                    break
                fi
            fi
        done

        if [[ "$blocked" == "true" ]]; then continue; fi

        local id
        id=$(get_frontmatter_value "$ticket_file" "id")
        echo "$id"

        count=$((count + 1))
        if [[ -n "$limit" ]] && [[ $count -ge $limit ]]; then break; fi
    done
}

# List blocked tickets
ticket_blocked() {
    require_project

    # Sync before read operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    for ticket_file in "$TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue

        local state
        state=$(get_frontmatter_value "$ticket_file" "state")
        if [[ "$state" != "ready" ]]; then continue; fi

        # Check dependencies
        local deps
        deps=$(awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}' "$ticket_file")
        local blocking_deps=""

        for dep in $deps; do
            if [[ -z "$dep" ]]; then continue; fi
            local dep_file="$TICKETS_DIR/${dep}.md"
            if [[ -f "$dep_file" ]]; then
                local dep_state
                dep_state=$(get_frontmatter_value "$dep_file" "state")
                if [[ "$dep_state" != "done" ]]; then
                    blocking_deps="$blocking_deps $dep"
                fi
            fi
        done

        if [[ -n "$blocking_deps" ]]; then
            local id
            id=$(get_frontmatter_value "$ticket_file" "id")
            echo "$id blocked by:$blocking_deps"
        fi
    done
}

# Show dependency tree
ticket_tree() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket tree <id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    require_project

    # Sync before read operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    _print_tree "$id" 0
}

_print_tree() {
    local id="$1"
    local depth="$2"
    local indent=""

    for ((i = 0; i < depth; i++)); do
        indent="$indent  "
    done

    local ticket_path="$TICKETS_DIR/${id}.md"
    if [[ ! -f "$ticket_path" ]]; then
        echo "${indent}$id (not found)"
        return
    fi

    local state
    state=$(get_frontmatter_value "$ticket_path" "state")
    local title
    title=$(grep -m1 '^# ' "$ticket_path" | sed 's/^# //')

    if [[ $depth -eq 0 ]]; then
        echo "$id [$state] $title"
    else
        echo "${indent}└── $id [$state] $title"
    fi

    # Print dependencies
    local deps
    deps=$(awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}' "$ticket_path")
    for dep in $deps; do
        if [[ -z "$dep" ]]; then continue; fi
        _print_tree "$dep" $((depth + 1))
    done
}

# Merge worker branch to feature branch
# Usage: merge_to_feature <ticket-id> <worker-branch>
# Returns: 0 on success, EXIT_MERGE_CONFLICT on conflict
merge_to_feature() {
    local ticket_id="$1"
    local worker_branch="$2"
    local feature_branch="feature/$ticket_id"

    # Check if feature branch exists
    if ! git rev-parse --verify "$feature_branch" &>/dev/null; then
        warn "Feature branch $feature_branch not found, creating from worker branch"
        git branch "$feature_branch" "$worker_branch"
        return 0
    fi

    # Check if worker branch has commits ahead of feature branch
    local ahead
    ahead=$(git rev-list --count "$feature_branch..$worker_branch" 2>/dev/null || echo "0")
    if [[ "$ahead" == "0" ]]; then
        info "Worker branch has no new commits to merge"
        return 0
    fi

    info "Merging $worker_branch into $feature_branch ($ahead commits)..."

    # Save current branch
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    # Checkout feature branch and merge
    if ! git checkout "$feature_branch" --quiet 2>/dev/null; then
        error "Failed to checkout feature branch: $feature_branch"
        return "$EXIT_ERROR"
    fi

    local merge_output
    if merge_output=$(git merge "$worker_branch" --no-edit 2>&1); then
        info "Successfully merged $worker_branch into $feature_branch"
        # Return to original branch
        git checkout "$current_branch" --quiet 2>/dev/null || true
        return 0
    else
        error "Merge conflict detected!"
        error "Output: $merge_output"
        error ""
        error "To resolve:"
        error "  1. cd to main project root"
        error "  2. git checkout $feature_branch"
        error "  3. Resolve conflicts manually"
        error "  4. git commit"
        error "  5. Retry the transition"
        # Abort the merge
        git merge --abort 2>/dev/null || true
        # Return to original branch
        git checkout "$current_branch" --quiet 2>/dev/null || true
        return "$EXIT_MERGE_CONFLICT"
    fi
}

# Transition ticket state
ticket_transition() {
    if [[ $# -lt 2 ]]; then
        error "Usage: wiggum ticket transition <id> <state> [--no-sync]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    local new_state="$2"
    shift 2

    local no_sync=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --no-sync)
            no_sync=true
            shift
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project

    # Sync before write operation
    if [[ "$no_sync" != "true" ]]; then
        ticket_sync_pull || error "Failed to pull ticket changes"
    fi

    local ticket_path="$TICKETS_DIR/${id}.md"
    local current_state
    current_state=$(get_frontmatter_value "$ticket_path" "state")

    # Validate state
    local valid=false
    for s in "${VALID_STATES[@]}"; do
        if [[ "$new_state" == "$s" ]]; then
            valid=true
            break
        fi
    done

    if [[ "$valid" != "true" ]]; then
        error "Invalid state: $new_state"
        error "Valid states: ${VALID_STATES[*]}"
        exit "$EXIT_INVALID_TRANSITION"
    fi

    # Check transition is allowed (space-delimited list)
    local allowed="${TRANSITIONS[$current_state]:-}"
    if [[ ! " $allowed " == *" $new_state "* ]]; then
        error "Cannot transition from '$current_state' to '$new_state'"
        error "Allowed transitions from '$current_state': $allowed"
        exit "$EXIT_INVALID_TRANSITION"
    fi

    # For in-progress -> review transitions, merge worker branch to feature branch
    if [[ "$current_state" == "in-progress" ]] && [[ "$new_state" == "review" ]]; then
        local assigned_agent
        assigned_agent=$(get_frontmatter_value "$ticket_path" "assigned_agent_id")
        if [[ -n "$assigned_agent" ]] && [[ "$assigned_agent" == worker-* ]]; then
            info "Merging worker changes to feature branch before review..."
            if ! merge_to_feature "$id" "$assigned_agent"; then
                error "Cannot transition to review: merge conflicts must be resolved first"
                exit "$EXIT_MERGE_CONFLICT"
            fi
        fi
    fi

    # Update state
    set_frontmatter_value "$ticket_path" "state" "$new_state"

    # Sync after write operation (hooks triggered by post-receive in bare repo)
    # shellcheck disable=SC2015
    if [[ "$no_sync" != "true" ]]; then
        ticket_sync_push "Transition $id: $current_state → $new_state" || error "Failed to push ticket changes"
    fi

    success "Transitioned $id: $current_state -> $new_state"
}

# Edit ticket in editor
ticket_edit() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket edit <id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    require_project
    load_config

    ticket_sync_pull || error "Failed to pull ticket changes"
    local ticket_path="$TICKETS_DIR/${id}.md"
    ${WIGGUM_EDITOR} "$ticket_path"
    ticket_sync_push || error "Failed to push ticket changes"
}

# Add comment to ticket
ticket_comment() {
    if [[ $# -lt 3 ]]; then
        error "Usage: wiggum ticket comment <id> <source> <message>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    local source="$2"
    shift 2
    local message="$*"

    require_project

    # Sync before write operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    local ticket_path="$TICKETS_DIR/${id}.md"

    # Append comment to ticket
    local comment_entry
    comment_entry="
### From $source ($(human_timestamp))

$message
"

    # Find the ## Comments section and append after it
    local temp
    temp=$(mktemp)
    awk -v comment="$comment_entry" '
        /^## Comments/ {
            print
            print comment
            next
        }
        { print }
    ' "$ticket_path" >"$temp"
    mv "$temp" "$ticket_path"

    # Sync after write operation
    ticket_sync_push "Comments on $id from $source" || error "Failed to push ticket changes"

    # Pinging done in hook
    ## Ping assigned agent if any
    #local agent_id
    #agent_id=$(get_frontmatter_value "$ticket_path" "assigned_agent_id")
    #if [[ -n "$agent_id" ]]; then
    #    load_config
    #    if session_exists "$WIGGUM_SESSION"; then
    #        local tmux_pane_id
    #        tmux_pane_id=$(get_tmux_pane_id "$agent_id")
    #        if [[ -n "$tmux_pane_id" ]]; then
    #            send_pane_input "$tmux_pane_id" "# Comments added to your ticket. Please address."
    #        fi
    #    fi
    #fi

    success "Added comment to $id"
}

# Assign an agent to a ticket
ticket_assign() {
    if [[ $# -lt 2 ]]; then
        error "Usage: wiggum ticket assign <ticket-id> <agent-id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    local agent_id="$2"

    require_project

    # Sync before write operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    local ticket_path="$TICKETS_DIR/${id}.md"
    if [[ ! -f "$ticket_path" ]]; then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi

    # Set assignment fields
    set_frontmatter_value "$ticket_path" "assigned_agent_id" "$agent_id"
    set_frontmatter_value "$ticket_path" "assigned_at" "$(timestamp)"

    # Sync after write operation
    ticket_sync_push "Assign $agent_id to $id" || error "Failed to push ticket changes"

    success "Assigned $agent_id to $id"
}

# Unassign the current agent from a ticket
ticket_unassign() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket unassign <ticket-id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"

    require_project

    # Sync before write operation
    ticket_sync_pull || error "Failed to pull ticket changes"

    local ticket_path="$TICKETS_DIR/${id}.md"
    if [[ ! -f "$ticket_path" ]]; then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi

    local prev_agent
    prev_agent=$(get_frontmatter_value "$ticket_path" "assigned_agent_id")

    # Clear assignment fields
    set_frontmatter_value "$ticket_path" "assigned_agent_id" ""
    set_frontmatter_value "$ticket_path" "assigned_at" ""

    # Sync after write operation
    ticket_sync_push "Unassign $id" || error "Failed to push ticket changes"

    if [[ -n "$prev_agent" ]]; then
        success "Unassigned $prev_agent from $id"
    else
        success "Cleared assignment on $id"
    fi
}
