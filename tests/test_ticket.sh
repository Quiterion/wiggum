#!/bin/bash
#
# test_ticket.sh - Ticket management tests
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests: Ticket create
#

test_ticket_create_basic() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test ticket")

    assert_file_exists ".wiggum/tickets/${ticket_id}.md" "Ticket file should exist"
}

test_ticket_create_with_type() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Bug fix" --type bug)

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "type: bug" "Ticket should have bug type"
}

test_ticket_create_with_priority() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Urgent task" --priority 1)

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "priority: 1" "Ticket should have priority 1"
}

test_ticket_create_initial_state() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "New ticket")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "state: ready" "New ticket should be in ready state"
}

test_ticket_create_with_dependency() {
    "$WIGGUM_BIN" init
    local dep_id
    dep_id=$("$WIGGUM_BIN" ticket create "Dependency")

    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Dependent" --dep "$dep_id")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "$dep_id" "Ticket should reference dependency"
}

test_ticket_create_has_title() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "My awesome feature")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "# My awesome feature" "Ticket should have title as H1"
}

test_ticket_create_with_description() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "With description" --description "This is a custom description")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "This is a custom description" "Ticket should have custom description"
    # Should not have placeholder
    if [[ "$content" == *"[Add description here]"* ]]; then
        echo "Should not have placeholder description"
        return 1
    fi
}

test_ticket_create_with_description_short_flag() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "With short desc" -d "Short flag description")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "Short flag description" "Ticket should have description from -d flag"
}

test_ticket_create_with_acceptance_test() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "With AC" --acceptance-test "Tests should pass")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "- [ ] Tests should pass" "Ticket should have acceptance criterion"
    # Should not have placeholder
    if [[ "$content" == *"[Add criteria]"* ]]; then
        echo "Should not have placeholder criteria"
        return 1
    fi
}

test_ticket_create_with_multiple_acceptance_tests() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Multiple AC" \
        --acceptance-test "First criterion" \
        --acceptance-test "Second criterion" \
        --acceptance-test "Third criterion")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "- [ ] First criterion" "Should have first criterion"
    assert_contains "$content" "- [ ] Second criterion" "Should have second criterion"
    assert_contains "$content" "- [ ] Third criterion" "Should have third criterion"
}

test_ticket_create_with_all_flags() {
    "$WIGGUM_BIN" init
    local dep_id
    dep_id=$("$WIGGUM_BIN" ticket create "Dependency ticket")

    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Full ticket" \
        --type feature \
        --priority 0 \
        --dep "$dep_id" \
        --description "Complete description" \
        --acceptance-test "AC one" \
        --acceptance-test "AC two")

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "type: feature" "Should have feature type"
    assert_contains "$content" "priority: 0" "Should have priority 0"
    assert_contains "$content" "$dep_id" "Should reference dependency"
    assert_contains "$content" "Complete description" "Should have description"
    assert_contains "$content" "- [ ] AC one" "Should have first AC"
    assert_contains "$content" "- [ ] AC two" "Should have second AC"
}

#
# Tests: Ticket list
#

test_ticket_list_empty() {
    "$WIGGUM_BIN" init
    local output
    output=$("$WIGGUM_BIN" ticket list)
    # Should not fail, may show empty table
    assert_contains "$output" "ID" "Should show table headers"
}

test_ticket_list_shows_tickets() {
    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" ticket create "First ticket"
    "$WIGGUM_BIN" ticket create "Second ticket"

    local output
    output=$("$WIGGUM_BIN" ticket list)
    assert_contains "$output" "First ticket" "Should show first ticket"
    assert_contains "$output" "Second ticket" "Should show second ticket"
}

test_ticket_list_filter_by_state() {
    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" ticket create "Ready ticket"

    local output
    output=$("$WIGGUM_BIN" ticket list --state ready)
    assert_contains "$output" "Ready ticket" "Should show ready ticket"

    output=$("$WIGGUM_BIN" ticket list --state in-progress)
    # Should not contain the ticket since it's not in-progress
    if [[ "$output" == *"Ready ticket"* ]]; then
        echo "Should not show ticket in different state"
        return 1
    fi
}

test_ticket_list_filter_by_type() {
    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" ticket create "Bug report" --type bug
    "$WIGGUM_BIN" ticket create "New feature" --type feature

    local output
    output=$("$WIGGUM_BIN" ticket list --type bug)
    assert_contains "$output" "Bug report" "Should show bug"

    if [[ "$output" == *"New feature"* ]]; then
        echo "Should not show feature when filtering by bug"
        return 1
    fi
}

#
# Tests: Ticket show
#

test_ticket_show_displays_content() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Show me")

    local output
    output=$("$WIGGUM_BIN" ticket show "$ticket_id")
    assert_contains "$output" "# Show me" "Should show ticket title"
    assert_contains "$output" "id: $ticket_id" "Should show ticket ID"
}

test_ticket_show_partial_id() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Partial match")

    # Use just the numeric part (after tk-)
    local partial="${ticket_id#tk-}"

    local output
    output=$("$WIGGUM_BIN" ticket show "$partial")
    assert_contains "$output" "# Partial match" "Should match partial ID"
}

test_ticket_show_not_found() {
    "$WIGGUM_BIN" init

    if "$WIGGUM_BIN" ticket show "nonexistent" 2>/dev/null; then
        echo "Should fail for nonexistent ticket"
        return 1
    fi
}

#
# Tests: Ticket transition to in-progress
#

test_ticket_start() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Start me")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "state: in-progress" "Ticket should be in-progress"
}

test_ticket_start_from_ready_only() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Double start")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress

    if "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress 2>/dev/null; then
        echo "Should fail to start already in-progress ticket"
        return 1
    fi
}

#
# Tests: Ticket transition
#

test_ticket_transition_valid() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Transition me")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "state: in-progress" "Should be in in-progress state"
}

test_ticket_transition_full_workflow() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Full workflow")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" review --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" qa --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" "done" --no-hooks

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "state: done" "Should complete full workflow"
}

test_ticket_transition_invalid() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Invalid transition")

    # Try to skip from ready to done
    if "$WIGGUM_BIN" ticket transition "$ticket_id" "done" 2>/dev/null; then
        echo "Should reject invalid transition"
        return 1
    fi
}

test_ticket_transition_review_rejection() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Rejected")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" review --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks # Rejected!

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "state: in-progress" "Should allow review rejection"
}

#
# Tests: Ticket ready
#

test_ticket_ready_lists_unblocked() {
    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" ticket create "Ready ticket"

    local output
    output=$("$WIGGUM_BIN" ticket ready)
    assert_contains "$output" "tk-" "Should list ready ticket"
}

test_ticket_ready_excludes_blocked() {
    "$WIGGUM_BIN" init
    local dep_id
    dep_id=$("$WIGGUM_BIN" ticket create "Blocker")

    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Blocked" --dep "$dep_id")

    local output
    output=$("$WIGGUM_BIN" ticket ready)

    # Should show the blocker but not the blocked ticket
    assert_contains "$output" "$dep_id" "Should show unblocked ticket"

    if [[ "$output" == *"$ticket_id"* ]]; then
        echo "Should not show blocked ticket"
        return 1
    fi
}

test_ticket_ready_with_limit() {
    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" ticket create "First"
    "$WIGGUM_BIN" ticket create "Second"
    "$WIGGUM_BIN" ticket create "Third"

    local output
    output=$("$WIGGUM_BIN" ticket ready --limit 1)

    # Count lines with ticket IDs
    local count
    count=$(echo "$output" | grep -c "tk-" || true)
    assert_eq "1" "$count" "Should limit to 1 ticket"
}

#
# Tests: Ticket blocked
#

test_ticket_blocked_shows_blockers() {
    "$WIGGUM_BIN" init
    local dep_id
    dep_id=$("$WIGGUM_BIN" ticket create "Blocker")

    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Blocked" --dep "$dep_id")

    local output
    output=$("$WIGGUM_BIN" ticket blocked)

    assert_contains "$output" "$ticket_id" "Should show blocked ticket"
    assert_contains "$output" "$dep_id" "Should show what's blocking"
}

#
# Tests: Ticket tree
#

test_ticket_tree_shows_deps() {
    "$WIGGUM_BIN" init
    local dep_id
    dep_id=$("$WIGGUM_BIN" ticket create "Dependency")

    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Parent" --dep "$dep_id")

    local output
    output=$("$WIGGUM_BIN" ticket tree "$ticket_id")

    assert_contains "$output" "$ticket_id" "Should show parent"
    assert_contains "$output" "$dep_id" "Should show dependency"
    assert_contains "$output" "└──" "Should show tree structure"
}

#
# Tests: Ticket comment
#

test_ticket_comment_appends() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Comment target")

    "$WIGGUM_BIN" ticket comment "$ticket_id" reviewer "Looks good but needs tests"

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "From reviewer" "Should show comment source"
    assert_contains "$content" "Looks good but needs tests" "Should show comment message"
}

test_ticket_comment_multiple() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Multiple comment")

    "$WIGGUM_BIN" ticket comment "$ticket_id" alice "First comment"
    "$WIGGUM_BIN" ticket comment "$ticket_id" bob "Second comment"

    local content
    content=$(cat ".wiggum/tickets/${ticket_id}.md")
    assert_contains "$content" "From alice" "Should show first comment"
    assert_contains "$content" "From bob" "Should show second comment"
}

#
# Tests: Utilities
#

test_require_project_fails_outside() {
    # Don't init - we're outside a project
    if "$WIGGUM_BIN" ticket list 2>/dev/null; then
        echo "Should fail outside a wiggum project"
        return 1
    fi
}

test_id_format() {
    "$WIGGUM_BIN" init
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "ID format test")

    # ID should match tk-XXXX format
    if [[ ! "$ticket_id" =~ ^tk-[0-9a-f]{4}$ ]]; then
        echo "ID should match tk-XXXX format, got: $ticket_id"
        return 1
    fi
}

#
# Test list
#

TICKET_TESTS=(
    # Create
    "Ticket create basic:test_ticket_create_basic"
    "Ticket create with type:test_ticket_create_with_type"
    "Ticket create with priority:test_ticket_create_with_priority"
    "Ticket create initial state:test_ticket_create_initial_state"
    "Ticket create with dependency:test_ticket_create_with_dependency"
    "Ticket create has title:test_ticket_create_has_title"
    "Ticket create with description:test_ticket_create_with_description"
    "Ticket create with description short flag:test_ticket_create_with_description_short_flag"
    "Ticket create with acceptance test:test_ticket_create_with_acceptance_test"
    "Ticket create with multiple acceptance tests:test_ticket_create_with_multiple_acceptance_tests"
    "Ticket create with all flags:test_ticket_create_with_all_flags"

    # List
    "Ticket list empty:test_ticket_list_empty"
    "Ticket list shows tickets:test_ticket_list_shows_tickets"
    "Ticket list filter by state:test_ticket_list_filter_by_state"
    "Ticket list filter by type:test_ticket_list_filter_by_type"

    # Show
    "Ticket show displays content:test_ticket_show_displays_content"
    "Ticket show partial ID:test_ticket_show_partial_id"
    "Ticket show not found:test_ticket_show_not_found"

    # Start (transition to in-progress)
    "Ticket start:test_ticket_start"
    "Ticket start from ready only:test_ticket_start_from_ready_only"

    # Transition
    "Ticket transition valid:test_ticket_transition_valid"
    "Ticket transition full workflow:test_ticket_transition_full_workflow"
    "Ticket transition invalid:test_ticket_transition_invalid"
    "Ticket transition review rejection:test_ticket_transition_review_rejection"

    # Ready/blocked
    "Ticket ready lists unblocked:test_ticket_ready_lists_unblocked"
    "Ticket ready excludes blocked:test_ticket_ready_excludes_blocked"
    "Ticket ready with limit:test_ticket_ready_with_limit"
    "Ticket blocked shows blockers:test_ticket_blocked_shows_blockers"

    # Tree
    "Ticket tree shows deps:test_ticket_tree_shows_deps"

    # Comment
    "Ticket comment appends:test_ticket_comment_appends"
    "Ticket comment multiple:test_ticket_comment_multiple"

    # Utilities
    "Require project fails outside:test_require_project_fails_outside"
    "ID format:test_id_format"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running ticket tests..."
    run_tests "${1:-}" TICKET_TESTS
    print_summary
fi
