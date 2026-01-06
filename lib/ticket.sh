#!/bin/bash
#
# ticket.sh - Ticket management system
#
# Supports both bare repo (main project) and clone (agent worktrees)
#
# Note: Ticket states and transitions are now configurable via ticket_types.sh
# The old hardcoded VALID_STATES and TRANSITIONS arrays have been replaced
# with functions that read from .wiggum/ticket_types.json (or use defaults)

###############################################################################
# TICKET DATA LAYER (CRUD API)
#
# INVARIANT: Only functions in this section may access $TICKETS_DIR directly.
# All other functions MUST use these CRUD operations.
#
# Every CRUD operation:
# - Pulls from origin before reading
# - Pushes to origin after writing
###############################################################################

# Track whether we've already synced in the current operation
# This avoids redundant pulls when doing batch operations
_TICKET_SYNCED=false

# Reset sync flag (call at start of each CLI command)
_ticket_reset_sync() {
    _TICKET_SYNCED=false
}

# Ensure tickets are synced (pull) - idempotent within operation
_ticket_ensure_sync() {
    if [[ "$_TICKET_SYNCED" == "true" ]]; then
        return 0
    fi
    ticket_sync_pull || { error "Failed to pull ticket changes"; return 1; }
    _TICKET_SYNCED=true
}

# Check if we're using a clone (vs bare repo)
has_ticket_clone() {
    [[ -d "$TICKETS_DIR/.git" ]]
}

# List all ticket IDs (CRUD - pulls first)
# Usage: list_ticket_ids
# Returns: newline-separated list of ticket IDs
list_ticket_ids() {
    require_project
    _ticket_ensure_sync || return 1

    for ticket_file in "$TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue
        [[ "$(basename "$ticket_file")" == ".gitkeep" ]] && continue
        basename "$ticket_file" .md
    done
}

# Get ticket file path (internal CRUD helper)
# Usage: _ticket_path <id>
# Returns: path to ticket file (does NOT check existence)
_ticket_path() {
    echo "$TICKETS_DIR/${1}.md"
}

# Check if ticket exists (CRUD - pulls first)
# Usage: ticket_exists <id>
# Returns: 0 if exists, 1 otherwise
ticket_exists() {
    local id="$1"
    require_project
    _ticket_ensure_sync || return 1
    [[ -f "$(_ticket_path "$id")" ]]
}

# Read ticket content (CRUD - pulls first)
# Usage: read_ticket_content <id>
# Returns: ticket content to stdout
read_ticket_content() {
    local id="$1"
    require_project
    _ticket_ensure_sync || return 1

    local ticket_path
    ticket_path=$(_ticket_path "$id")
    if [[ ! -f "$ticket_path" ]]; then
        return 1
    fi
    cat "$ticket_path"
}

# Write ticket content (CRUD - pulls first, pushes after)
# Usage: write_ticket_content <id> <content> [commit_msg]
write_ticket_content() {
    local id="$1"
    local content="$2"
    local commit_msg="${3:-Update ticket: $id}"

    require_project
    _ticket_ensure_sync || return 1
    echo "$content" >"$(_ticket_path "$id")"
    ticket_sync_push "$commit_msg" || { error "Failed to push ticket changes"; return 1; }
}

# Get frontmatter value from ticket file (INTERNAL - do NOT call directly)
# Usage: _get_frontmatter_value <file_path> <key>
# Note: Caller must ensure sync before calling. External code should use get_ticket_field()
_get_frontmatter_value() {
    local file="$1"
    local key="$2"
    awk -v key="$key" '
        /^---$/ { in_fm = !in_fm; next }
        in_fm && $1 == key":" { print $2; exit }
    ' "$file"
}

# Set frontmatter value in ticket file (INTERNAL - do NOT call directly)
# Usage: _set_frontmatter_value <file_path> <key> <value>
# Note: Caller must ensure sync before calling. External code should use set_ticket_field()
_set_frontmatter_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    local temp
    temp=$(mktemp)
    awk -v key="$key" -v val="$value" '
        $0 ~ "^"key":" { print key": "val; next }
        { print }
    ' "$file" > "$temp"
    mv "$temp" "$file"
}

# Get a ticket field value (CRUD - pulls first)
# Usage: get_ticket_field <id> <field>
# Returns: field value to stdout
get_ticket_field() {
    local id="$1"
    local field="$2"
    require_project
    _ticket_ensure_sync || return 1

    local ticket_path
    ticket_path=$(_ticket_path "$id")
    if [[ ! -f "$ticket_path" ]]; then
        return 1
    fi
    _get_frontmatter_value "$ticket_path" "$field"
}

# Set a ticket field value (CRUD - pulls first, pushes after)
# Usage: set_ticket_field <id> <field> <value> [commit_msg]
set_ticket_field() {
    local id="$1"
    local field="$2"
    local value="$3"
    local commit_msg="${4:-Update $id: $field = $value}"

    require_project
    _ticket_ensure_sync || return 1

    local ticket_path
    ticket_path=$(_ticket_path "$id")
    if [[ ! -f "$ticket_path" ]]; then
        return 1
    fi
    _set_frontmatter_value "$ticket_path" "$field" "$value"
    ticket_sync_push "$commit_msg" || { error "Failed to push ticket changes"; return 1; }
}

# Iterate over ticket files (internal helper for batch operations)
# Usage: for_each_ticket <callback_function>
# Callback receives: ticket_file_path ticket_id
# Note: Ensures sync once at start
_for_each_ticket() {
    local callback="$1"
    require_project
    _ticket_ensure_sync || return 1

    for ticket_file in "$TICKETS_DIR"/*.md; do
        [[ -f "$ticket_file" ]] || continue
        [[ "$(basename "$ticket_file")" == ".gitkeep" ]] && continue
        local ticket_id
        ticket_id=$(basename "$ticket_file" .md)
        "$callback" "$ticket_file" "$ticket_id"
    done
}

###############################################################################
# HIGH-LEVEL TICKET API (uses CRUD layer above)
###############################################################################

# Read ticket content with ID resolution (CLI-facing)
# Usage: read_ticket <id>
read_ticket() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket show <id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"

    local content
    if ! content=$(read_ticket_content "$id"); then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi
    echo "$content"
}

# Write ticket content (CLI-facing wrapper)
write_ticket() {
    local id="$1"
    local content="$2"
    local commit_msg="${3:-Update ticket: $id}"
    write_ticket_content "$id" "$content" "$commit_msg"
}

# Get frontmatter value from ticket by ID (CLI-facing)
# Usage: get_ticket_value <id> <key>
get_ticket_value() {
    local id="$1"
    local key="$2"
    local content
    content=$(read_ticket "$id")
    echo "$content" | awk -F': ' "/^${key}:/{print \$2; exit}"
}

# Set frontmatter value in ticket by ID (CLI-facing)
# Usage: set_ticket_value <id> <key> <value> [commit_msg]
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
# Priority: non-done tickets first, then most recently assigned
get_agent_ticket() {
    local agent_id="$1"
    require_project
    _ticket_ensure_sync || return 1

    local best_ticket=""
    local best_assigned_at=""
    local best_is_done=true

    # Use internal helper to iterate (sync already done)
    _get_agent_ticket_check() {
        local ticket_file="$1"
        local ticket_id="$2"

        local assigned
        assigned=$(_get_frontmatter_value "$ticket_file" "assigned_agent_id")
        if [[ "$assigned" == "$agent_id" ]]; then
            local state assigned_at
            state=$(_get_frontmatter_value "$ticket_file" "state")
            assigned_at=$(_get_frontmatter_value "$ticket_file" "assigned_at")

            local is_done=false
            [[ "$state" == "done" || "$state" == "closed" ]] && is_done=true

            # Priority: non-done tickets over done tickets
            # Within same priority: most recently assigned wins
            if [[ -z "$best_ticket" ]]; then
                best_ticket="$ticket_id"
                best_assigned_at="$assigned_at"
                best_is_done="$is_done"
            elif [[ "$best_is_done" == "true" && "$is_done" == "false" ]]; then
                best_ticket="$ticket_id"
                best_assigned_at="$assigned_at"
                best_is_done="$is_done"
            elif [[ "$best_is_done" == "$is_done" ]]; then
                if [[ "$assigned_at" > "$best_assigned_at" ]]; then
                    best_ticket="$ticket_id"
                    best_assigned_at="$assigned_at"
                    best_is_done="$is_done"
                fi
            fi
        fi
    }

    _for_each_ticket _get_agent_ticket_check
    echo "$best_ticket"
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

# State transition rules are now loaded from ticket_types.sh
# See: get_valid_states(), get_valid_transitions(), is_valid_transition()

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
    _ticket_ensure_sync || exit 1

    echo ""
    printf "${BOLD}%-10s %-10s %-10s %-3s %-40s${NC}\n" "ID" "STATE" "TYPE" "PRI" "TITLE"
    echo "-------------------------------------------------------------------------------"

    # Use CRUD layer for iteration
    _ticket_list_row() {
        local ticket_file="$1"
        local id="$2"

        local state type priority title
        state=$(_get_frontmatter_value "$ticket_file" "state")
        type=$(_get_frontmatter_value "$ticket_file" "type")
        priority=$(_get_frontmatter_value "$ticket_file" "priority")

        # Apply filters
        if [[ -n "$filter_state" ]] && [[ "$state" != "$filter_state" ]]; then return; fi
        if [[ -n "$filter_type" ]] && [[ "$type" != "$filter_type" ]]; then return; fi

        # Get title (first H1)
        title=$(grep -m1 '^# ' "$ticket_file" | sed 's/^# //')

        # Truncate title if needed
        if [[ ${#title} -gt 38 ]]; then title="${title:0:35}..."; fi

        printf "%-10s %-10s %-10s %-3s %-40s\n" "$id" "$state" "$type" "$priority" "$title"
    }

    _for_each_ticket _ticket_list_row

    echo ""
}

# Show ticket details
ticket_show() {
    if [[ $# -lt 1 ]]; then
        error "Usage: wiggum ticket show <id>"
        exit "$EXIT_INVALID_ARGS"
    fi

    # Use the CRUD read_ticket function which handles sync and resolution
    read_ticket "$1"
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
    _ticket_ensure_sync || exit 1

    local count=0
    local ready_tickets=""

    # Use CRUD layer for iteration
    _ticket_ready_check() {
        local ticket_file="$1"
        local ticket_id="$2"

        # Check if already hit limit
        if [[ -n "$limit" ]] && [[ $count -ge $limit ]]; then return; fi

        local state
        state=$(_get_frontmatter_value "$ticket_file" "state")
        if [[ "$state" != "ready" ]]; then return; fi

        # Check dependencies
        local blocked=false
        local deps
        deps=$(awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}' "$ticket_file")

        for dep in $deps; do
            if [[ -z "$dep" ]]; then continue; fi
            # Check dependency state via CRUD
            local dep_content dep_state
            if dep_content=$(read_ticket_content "$dep" 2>/dev/null); then
                dep_state=$(echo "$dep_content" | awk '/^state:/{print $2; exit}')
                if [[ "$dep_state" != "done" ]]; then
                    blocked=true
                    break
                fi
            fi
        done

        if [[ "$blocked" == "true" ]]; then return; fi

        echo "$ticket_id"
        count=$((count + 1))
    }

    _for_each_ticket _ticket_ready_check
}

# List blocked tickets
ticket_blocked() {
    require_project
    _ticket_ensure_sync || exit 1

    # Use CRUD layer for iteration
    _ticket_blocked_check() {
        local ticket_file="$1"
        local ticket_id="$2"

        local state
        state=$(_get_frontmatter_value "$ticket_file" "state")
        if [[ "$state" != "ready" ]]; then return; fi

        # Check dependencies
        local deps
        deps=$(awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}' "$ticket_file")
        local blocking_deps=""

        for dep in $deps; do
            if [[ -z "$dep" ]]; then continue; fi
            # Check dependency state via CRUD
            local dep_content dep_state
            if dep_content=$(read_ticket_content "$dep" 2>/dev/null); then
                dep_state=$(echo "$dep_content" | awk '/^state:/{print $2; exit}')
                if [[ "$dep_state" != "done" ]]; then
                    blocking_deps="$blocking_deps $dep"
                fi
            fi
        done

        if [[ -n "$blocking_deps" ]]; then
            echo "$ticket_id blocked by:$blocking_deps"
        fi
    }

    _for_each_ticket _ticket_blocked_check
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
    _ticket_ensure_sync || exit 1

    _print_tree "$id" 0
}

_print_tree() {
    local id="$1"
    local depth="$2"
    local indent=""

    for ((i = 0; i < depth; i++)); do
        indent="$indent  "
    done

    # Use CRUD layer to read ticket
    local content
    if ! content=$(read_ticket_content "$id" 2>/dev/null); then
        echo "${indent}$id (not found)"
        return
    fi

    local state
    state=$(echo "$content" | awk '/^state:/{print $2; exit}')
    local title
    title=$(echo "$content" | grep -m1 '^# ' | sed 's/^# //')

    if [[ $depth -eq 0 ]]; then
        echo "$id [$state] $title"
    else
        echo "${indent}└── $id [$state] $title"
    fi

    # Print dependencies
    local deps
    deps=$(echo "$content" | awk '/^depends_on:/{flag=1; next} /^[a-z]/{flag=0} flag && /^ *-/{print $2}')
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
# Hooks are now invoked directly from this function (not via git hooks)
# Use --no-hooks to skip hook invocation (sync always happens)
# Sync invariants are mandatory and cannot be disabled.
ticket_transition() {
    if [[ $# -lt 2 ]]; then
        error "Usage: wiggum ticket transition <id> <state> [--no-hooks]"
        exit "$EXIT_INVALID_ARGS"
    fi

    local id
    id=$(resolve_ticket_id "$1") || exit "$EXIT_TICKET_NOT_FOUND"
    local new_state="$2"
    shift 2

    local no_hooks=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --no-hooks)
            no_hooks=true
            shift
            ;;
        *)
            shift
            ;;
        esac
    done

    require_project
    load_config

    # Use CRUD layer for sync (invariant: always sync before read)
    _ticket_ensure_sync || exit 1

    # Use CRUD layer for path resolution
    local ticket_path
    ticket_path=$(_ticket_path "$id")
    local current_state
    current_state=$(_get_frontmatter_value "$ticket_path" "state")

    # Validate state using ticket_types
    local valid_states
    valid_states=$(get_valid_states)
    local valid=false
    for s in $valid_states; do
        if [[ "$new_state" == "$s" ]]; then
            valid=true
            break
        fi
    done

    if [[ "$valid" != "true" ]]; then
        error "Invalid state: $new_state"
        error "Valid states: $valid_states"
        exit "$EXIT_INVALID_TRANSITION"
    fi

    # Check transition is allowed using ticket_types
    if ! is_valid_transition "$current_state" "$new_state"; then
        local allowed
        allowed=$(get_valid_transitions "$current_state")
        error "Cannot transition from '$current_state' to '$new_state'"
        error "Allowed transitions from '$current_state': $allowed"
        exit "$EXIT_INVALID_TRANSITION"
    fi

    # Run pre-transition hooks (in worktree, before state change)
    if [[ "$no_hooks" != "true" ]]; then
        local pre_hooks
        pre_hooks=$(get_transition_hooks "$current_state" "$new_state" "pre")
        for hook in $pre_hooks; do
            [[ -z "$hook" ]] && continue
            debug "Running pre-transition hook: $hook"
            export WIGGUM_PREV_STATE="$current_state"
            export WIGGUM_NEW_STATE="$new_state"
            export WIGGUM_HOOK_PHASE="pre"
            if ! run_hook "$hook" "$id"; then
                error "Pre-transition hook '$hook' failed - transition blocked"
                exit "$EXIT_ERROR"
            fi
        done
    fi

    # For in-progress -> review transitions, merge worker branch to feature branch
    if [[ "$current_state" == "in-progress" ]] && [[ "$new_state" == "review" ]]; then
        local assigned_agent
        assigned_agent=$(_get_frontmatter_value "$ticket_path" "assigned_agent_id")
        if [[ -n "$assigned_agent" ]] && [[ "$assigned_agent" == worker-* ]]; then
            info "Merging worker changes to feature branch before review..."
            if ! merge_to_feature "$id" "$assigned_agent"; then
                error "Cannot transition to review: merge conflicts must be resolved first"
                exit "$EXIT_MERGE_CONFLICT"
            fi
        fi
    fi

    # Update state (uses internal helper)
    _set_frontmatter_value "$ticket_path" "state" "$new_state"

    # Sync after write operation (invariant: always push after write)
    ticket_sync_push "Transition $id: $current_state → $new_state" || error "Failed to push ticket changes"

    # Run post-transition hooks (after successful sync)
    if [[ "$no_hooks" != "true" ]]; then
        local post_hooks
        post_hooks=$(get_transition_hooks "$current_state" "$new_state" "post")
        for hook in $post_hooks; do
            [[ -z "$hook" ]] && continue
            debug "Running post-transition hook: $hook"
            export WIGGUM_PREV_STATE="$current_state"
            export WIGGUM_NEW_STATE="$new_state"
            export WIGGUM_HOOK_PHASE="post"
            # Post-hooks run asynchronously and don't block transition
            run_hook "$hook" "$id" &
        done
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

    # Use CRUD layer for sync and path
    _ticket_ensure_sync || exit 1
    local ticket_path
    ticket_path=$(_ticket_path "$id")
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

    # Use CRUD layer for sync and path
    _ticket_ensure_sync || exit 1
    local ticket_path
    ticket_path=$(_ticket_path "$id")

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

    # Use CRUD layer for sync and path
    _ticket_ensure_sync || exit 1
    local ticket_path
    ticket_path=$(_ticket_path "$id")
    if [[ ! -f "$ticket_path" ]]; then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi

    # Set assignment fields (uses internal helpers)
    _set_frontmatter_value "$ticket_path" "assigned_agent_id" "$agent_id"
    _set_frontmatter_value "$ticket_path" "assigned_at" "$(timestamp)"

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

    # Use CRUD layer for sync and path
    _ticket_ensure_sync || exit 1
    local ticket_path
    ticket_path=$(_ticket_path "$id")
    if [[ ! -f "$ticket_path" ]]; then
        error "Ticket not found: $id"
        exit "$EXIT_TICKET_NOT_FOUND"
    fi

    local prev_agent
    prev_agent=$(_get_frontmatter_value "$ticket_path" "assigned_agent_id")

    # Clear assignment fields (uses internal helpers)
    _set_frontmatter_value "$ticket_path" "assigned_agent_id" ""
    _set_frontmatter_value "$ticket_path" "assigned_at" ""

    # Sync after write operation
    ticket_sync_push "Unassign $id" || error "Failed to push ticket changes"

    if [[ -n "$prev_agent" ]]; then
        success "Unassigned $prev_agent from $id"
    else
        success "Cleared assignment on $id"
    fi
}
