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
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Test ticket")

    assert_file_exists ".ralphs/tickets/${ticket_id}.md" "Ticket file should exist"
}

test_ticket_create_with_type() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Bug fix" --type bug)

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "type: bug" "Ticket should have bug type"
}

test_ticket_create_with_priority() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Urgent task" --priority 1)

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "priority: 1" "Ticket should have priority 1"
}

test_ticket_create_initial_state() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "New ticket")

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "state: ready" "New ticket should be in ready state"
}

test_ticket_create_with_dependency() {
    "$RALPHS_BIN" init --no-session
    local dep_id
    dep_id=$("$RALPHS_BIN" ticket create "Dependency")

    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Dependent" --dep "$dep_id")

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "$dep_id" "Ticket should reference dependency"
}

test_ticket_create_has_title() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "My awesome feature")

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "# My awesome feature" "Ticket should have title as H1"
}

#
# Tests: Ticket list
#

test_ticket_list_empty() {
    "$RALPHS_BIN" init --no-session
    local output
    output=$("$RALPHS_BIN" ticket list)
    # Should not fail, may show empty table
    assert_contains "$output" "ID" "Should show table headers"
}

test_ticket_list_shows_tickets() {
    "$RALPHS_BIN" init --no-session
    "$RALPHS_BIN" ticket create "First ticket"
    "$RALPHS_BIN" ticket create "Second ticket"

    local output
    output=$("$RALPHS_BIN" ticket list)
    assert_contains "$output" "First ticket" "Should show first ticket"
    assert_contains "$output" "Second ticket" "Should show second ticket"
}

test_ticket_list_filter_by_state() {
    "$RALPHS_BIN" init --no-session
    "$RALPHS_BIN" ticket create "Ready ticket"

    local output
    output=$("$RALPHS_BIN" ticket list --state ready)
    assert_contains "$output" "Ready ticket" "Should show ready ticket"

    output=$("$RALPHS_BIN" ticket list --state claimed)
    # Should not contain the ticket since it's not claimed
    if [[ "$output" == *"Ready ticket"* ]]; then
        echo "Should not show ticket in different state"
        return 1
    fi
}

test_ticket_list_filter_by_type() {
    "$RALPHS_BIN" init --no-session
    "$RALPHS_BIN" ticket create "Bug report" --type bug
    "$RALPHS_BIN" ticket create "New feature" --type feature

    local output
    output=$("$RALPHS_BIN" ticket list --type bug)
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
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Show me")

    local output
    output=$("$RALPHS_BIN" ticket show "$ticket_id")
    assert_contains "$output" "# Show me" "Should show ticket title"
    assert_contains "$output" "id: $ticket_id" "Should show ticket ID"
}

test_ticket_show_partial_id() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Partial match")

    # Use just the numeric part (after tk-)
    local partial="${ticket_id#tk-}"

    local output
    output=$("$RALPHS_BIN" ticket show "$partial")
    assert_contains "$output" "# Partial match" "Should match partial ID"
}

test_ticket_show_not_found() {
    "$RALPHS_BIN" init --no-session

    if "$RALPHS_BIN" ticket show "nonexistent" 2>/dev/null; then
        echo "Should fail for nonexistent ticket"
        return 1
    fi
}

#
# Tests: Ticket claim
#

test_ticket_claim() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Claim me")

    "$RALPHS_BIN" ticket claim "$ticket_id"

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "state: claimed" "Ticket should be claimed"
}

test_ticket_claim_sets_timestamp() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Claim with time")

    "$RALPHS_BIN" ticket claim "$ticket_id"

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "assigned_at:" "Should set assigned_at"
}

test_ticket_claim_already_claimed() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Double claim")

    "$RALPHS_BIN" ticket claim "$ticket_id"

    if "$RALPHS_BIN" ticket claim "$ticket_id" 2>/dev/null; then
        echo "Should fail to claim already claimed ticket"
        return 1
    fi
}

#
# Tests: Ticket transition
#

test_ticket_transition_valid() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Transition me")

    "$RALPHS_BIN" ticket claim "$ticket_id"
    "$RALPHS_BIN" ticket transition "$ticket_id" implement

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "state: implement" "Should be in implement state"
}

test_ticket_transition_full_workflow() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Full workflow")

    "$RALPHS_BIN" ticket claim "$ticket_id"
    "$RALPHS_BIN" ticket transition "$ticket_id" implement --no-hooks
    "$RALPHS_BIN" ticket transition "$ticket_id" review --no-hooks
    "$RALPHS_BIN" ticket transition "$ticket_id" qa --no-hooks
    "$RALPHS_BIN" ticket transition "$ticket_id" "done" --no-hooks

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "state: done" "Should complete full workflow"
}

test_ticket_transition_invalid() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Invalid transition")

    # Try to skip from ready to done
    if "$RALPHS_BIN" ticket transition "$ticket_id" "done" 2>/dev/null; then
        echo "Should reject invalid transition"
        return 1
    fi
}

test_ticket_transition_review_rejection() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Rejected")

    "$RALPHS_BIN" ticket claim "$ticket_id"
    "$RALPHS_BIN" ticket transition "$ticket_id" implement --no-hooks
    "$RALPHS_BIN" ticket transition "$ticket_id" review --no-hooks
    "$RALPHS_BIN" ticket transition "$ticket_id" implement --no-hooks  # Rejected!

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "state: implement" "Should allow review rejection"
}

#
# Tests: Ticket ready
#

test_ticket_ready_lists_unblocked() {
    "$RALPHS_BIN" init --no-session
    "$RALPHS_BIN" ticket create "Ready ticket"

    local output
    output=$("$RALPHS_BIN" ticket ready)
    assert_contains "$output" "tk-" "Should list ready ticket"
}

test_ticket_ready_excludes_blocked() {
    "$RALPHS_BIN" init --no-session
    local dep_id
    dep_id=$("$RALPHS_BIN" ticket create "Blocker")

    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Blocked" --dep "$dep_id")

    local output
    output=$("$RALPHS_BIN" ticket ready)

    # Should show the blocker but not the blocked ticket
    assert_contains "$output" "$dep_id" "Should show unblocked ticket"

    if [[ "$output" == *"$ticket_id"* ]]; then
        echo "Should not show blocked ticket"
        return 1
    fi
}

test_ticket_ready_with_limit() {
    "$RALPHS_BIN" init --no-session
    "$RALPHS_BIN" ticket create "First"
    "$RALPHS_BIN" ticket create "Second"
    "$RALPHS_BIN" ticket create "Third"

    local output
    output=$("$RALPHS_BIN" ticket ready --limit 1)

    # Count lines with ticket IDs
    local count
    count=$(echo "$output" | grep -c "tk-" || true)
    assert_eq "1" "$count" "Should limit to 1 ticket"
}

#
# Tests: Ticket blocked
#

test_ticket_blocked_shows_blockers() {
    "$RALPHS_BIN" init --no-session
    local dep_id
    dep_id=$("$RALPHS_BIN" ticket create "Blocker")

    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Blocked" --dep "$dep_id")

    local output
    output=$("$RALPHS_BIN" ticket blocked)

    assert_contains "$output" "$ticket_id" "Should show blocked ticket"
    assert_contains "$output" "$dep_id" "Should show what's blocking"
}

#
# Tests: Ticket tree
#

test_ticket_tree_shows_deps() {
    "$RALPHS_BIN" init --no-session
    local dep_id
    dep_id=$("$RALPHS_BIN" ticket create "Dependency")

    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Parent" --dep "$dep_id")

    local output
    output=$("$RALPHS_BIN" ticket tree "$ticket_id")

    assert_contains "$output" "$ticket_id" "Should show parent"
    assert_contains "$output" "$dep_id" "Should show dependency"
    assert_contains "$output" "└──" "Should show tree structure"
}

#
# Tests: Ticket feedback
#

test_ticket_feedback_appends() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Feedback target")

    "$RALPHS_BIN" ticket feedback "$ticket_id" reviewer "Looks good but needs tests"

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "From reviewer" "Should show feedback source"
    assert_contains "$content" "Looks good but needs tests" "Should show feedback message"
}

test_ticket_feedback_multiple() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Multiple feedback")

    "$RALPHS_BIN" ticket feedback "$ticket_id" alice "First comment"
    "$RALPHS_BIN" ticket feedback "$ticket_id" bob "Second comment"

    local content
    content=$(cat ".ralphs/tickets/${ticket_id}.md")
    assert_contains "$content" "From alice" "Should show first feedback"
    assert_contains "$content" "From bob" "Should show second feedback"
}

#
# Tests: Utilities
#

test_require_project_fails_outside() {
    # Don't init - we're outside a project
    if "$RALPHS_BIN" ticket list 2>/dev/null; then
        echo "Should fail outside a ralphs project"
        return 1
    fi
}

test_id_format() {
    "$RALPHS_BIN" init --no-session
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "ID format test")

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

    # List
    "Ticket list empty:test_ticket_list_empty"
    "Ticket list shows tickets:test_ticket_list_shows_tickets"
    "Ticket list filter by state:test_ticket_list_filter_by_state"
    "Ticket list filter by type:test_ticket_list_filter_by_type"

    # Show
    "Ticket show displays content:test_ticket_show_displays_content"
    "Ticket show partial ID:test_ticket_show_partial_id"
    "Ticket show not found:test_ticket_show_not_found"

    # Claim
    "Ticket claim:test_ticket_claim"
    "Ticket claim sets timestamp:test_ticket_claim_sets_timestamp"
    "Ticket claim already claimed:test_ticket_claim_already_claimed"

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

    # Feedback
    "Ticket feedback appends:test_ticket_feedback_appends"
    "Ticket feedback multiple:test_ticket_feedback_multiple"

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
