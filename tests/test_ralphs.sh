#!/bin/bash
#
# test_ralphs.sh - Comprehensive tests for ralphs CLI
#
# Usage: ./tests/test_ralphs.sh [test_name]
#
# If test_name is provided, only that test runs. Otherwise, all tests run.
#

# SC2064: We intentionally expand variables at trap definition time
# shellcheck disable=SC2064

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test directory (cleaned up on exit)
TEST_DIR=""

# Ralphs binary (resolved at script load time, before any cd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPHS_BIN="$SCRIPT_DIR/../bin/ralphs"

#
# Test framework
#

setup() {
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    if [[ ! -x "$RALPHS_BIN" ]]; then
        echo -e "${RED}Error: ralphs binary not found at $RALPHS_BIN${NC}"
        exit 1
    fi

    # Initialize git repo (required for ralphs)
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test User"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

trap teardown EXIT

run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))

    # Create fresh test environment
    teardown
    setup

    echo -n "  $test_name ... "

    # Run test in subshell to isolate failures
    local output
    if output=$("$test_func" 2>&1); then
        # Check if test was skipped
        if [[ "$output" == "SKIP:"* ]]; then
            echo -e "${YELLOW}SKIP${NC} (${output#SKIP: })"
            TESTS_PASSED=$((TESTS_PASSED + 1))  # Count skips as passes
        else
            echo -e "${GREEN}PASS${NC}"
            TESTS_PASSED=$((TESTS_PASSED + 1))
        fi
    else
        echo -e "${RED}FAIL${NC}"
        echo -e "${YELLOW}    Output:${NC}"
        echo "$output" | sed 's/^/    /'
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"

    if [[ "$expected" != "$actual" ]]; then
        echo "Assertion failed: $msg"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"

    if [[ "$haystack" != *"$needle"* ]]; then
        echo "Assertion failed: $msg"
        echo "  Expected to contain: $needle"
        echo "  Actual: $haystack"
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local msg="${2:-File should exist: $file}"

    if [[ ! -f "$file" ]]; then
        echo "Assertion failed: $msg"
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1"
    local msg="${2:-Directory should exist: $dir}"

    if [[ ! -d "$dir" ]]; then
        echo "Assertion failed: $msg"
        return 1
    fi
}

#
# Tests: CLI basics
#

test_help() {
    local output
    output=$("$RALPHS_BIN" --help)
    assert_contains "$output" "Usage:" "Help should show usage"
    assert_contains "$output" "Session Management:" "Help should list session commands"
    assert_contains "$output" "Ticket Management:" "Help should list ticket commands"
}

test_version() {
    local output
    output=$("$RALPHS_BIN" --version)
    assert_contains "$output" "ralphs" "Version should mention ralphs"
}

test_unknown_command() {
    if "$RALPHS_BIN" nonexistent 2>/dev/null; then
        echo "Should fail on unknown command"
        return 1
    fi
}

#
# Tests: Init
#

test_init_creates_ralphs_dir() {
    "$RALPHS_BIN" init --no-session
    assert_dir_exists ".ralphs" "Init should create .ralphs directory"
}

test_init_creates_config() {
    "$RALPHS_BIN" init --no-session
    assert_file_exists ".ralphs/config.sh" "Init should create config.sh"
}

test_init_creates_tickets_dir() {
    "$RALPHS_BIN" init --no-session
    assert_dir_exists ".ralphs/tickets" "Init should create tickets directory"
}

test_init_creates_hooks_dir() {
    "$RALPHS_BIN" init --no-session
    assert_dir_exists ".ralphs/hooks" "Init should create hooks directory"
}

test_init_creates_prompts_dir() {
    "$RALPHS_BIN" init --no-session
    assert_dir_exists ".ralphs/prompts" "Init should create prompts directory"
}

test_init_copies_default_hooks() {
    "$RALPHS_BIN" init --no-session
    assert_file_exists ".ralphs/hooks/on-claim" "Init should copy on-claim hook"
    assert_file_exists ".ralphs/hooks/on-implement-done" "Init should copy on-implement-done hook"
}

test_init_copies_default_prompts() {
    "$RALPHS_BIN" init --no-session
    assert_file_exists ".ralphs/prompts/supervisor.md" "Init should copy supervisor prompt"
    assert_file_exists ".ralphs/prompts/implementer.md" "Init should copy implementer prompt"
}

test_init_idempotent() {
    "$RALPHS_BIN" init --no-session
    "$RALPHS_BIN" init --no-session  # Should not fail
    assert_dir_exists ".ralphs"
}

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
# Tests: Tmux session management
#
# These tests require tmux and are skipped if unavailable
#

# Check if tmux is available
tmux_available() {
    command -v tmux &>/dev/null
}

# Generate unique session name for test isolation
test_session_name() {
    echo "ralphs-test-$$-$RANDOM"
}

# Cleanup any test sessions
cleanup_test_session() {
    local session="$1"
    tmux kill-session -t "$session" 2>/dev/null || true
}

test_init_creates_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export RALPHS_SESSION="$session"

    # Ensure cleanup on exit
    trap "cleanup_test_session '$session'" RETURN

    "$RALPHS_BIN" init --session "$session"

    # Verify session exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should exist after init"
        return 1
    fi

    # Cleanup
    cleanup_test_session "$session"
}

test_init_session_idempotent() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export RALPHS_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$RALPHS_BIN" init --session "$session"
    "$RALPHS_BIN" init --session "$session"  # Should not fail

    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should still exist"
        return 1
    fi

    cleanup_test_session "$session"
}

test_teardown_kills_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export RALPHS_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$RALPHS_BIN" init --session "$session"

    # Verify it exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should exist before teardown"
        return 1
    fi

    "$RALPHS_BIN" teardown --force

    # Verify it's gone
    if tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should be gone after teardown"
        return 1
    fi
}

test_list_panes_empty() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export RALPHS_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$RALPHS_BIN" init --session "$session"

    local output
    output=$("$RALPHS_BIN" list)

    # Should show table headers at minimum
    assert_contains "$output" "PANE" "Should show pane column header"

    cleanup_test_session "$session"
}

test_list_panes_json_format() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export RALPHS_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$RALPHS_BIN" init --session "$session"

    local output
    output=$("$RALPHS_BIN" list --format json)

    # Empty list should be valid JSON array
    if [[ "$output" != "[]" && "$output" != *"["* ]]; then
        echo "JSON format should return array, got: $output"
        return 1
    fi

    cleanup_test_session "$session"
}

test_status_shows_overview() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export RALPHS_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$RALPHS_BIN" init --session "$session"
    "$RALPHS_BIN" ticket create "Status test ticket"

    local output
    output=$("$RALPHS_BIN" status)

    assert_contains "$output" "Session:" "Should show session info"
    assert_contains "$output" "Tickets:" "Should show ticket count"

    cleanup_test_session "$session"
}

test_attach_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$RALPHS_BIN" init --no-session

    # Try to attach to non-existent session
    if "$RALPHS_BIN" attach --session "nonexistent-session-$$" 2>/dev/null; then
        echo "Attach should fail for non-existent session"
        return 1
    fi
}

test_teardown_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$RALPHS_BIN" init --no-session

    # Try to teardown non-existent session
    if "$RALPHS_BIN" teardown 2>/dev/null; then
        echo "Teardown should fail for non-existent session"
        return 1
    fi
}

#
# Main
#

main() {
    local filter="${1:-}"

    echo ""
    echo "Running ralphs tests..."
    echo ""

    # Collect all test functions
    local tests=(
        # CLI basics
        "CLI help:test_help"
        "CLI version:test_version"
        "CLI unknown command:test_unknown_command"

        # Init
        "Init creates .ralphs:test_init_creates_ralphs_dir"
        "Init creates config:test_init_creates_config"
        "Init creates tickets dir:test_init_creates_tickets_dir"
        "Init creates hooks dir:test_init_creates_hooks_dir"
        "Init creates prompts dir:test_init_creates_prompts_dir"
        "Init copies default hooks:test_init_copies_default_hooks"
        "Init copies default prompts:test_init_copies_default_prompts"
        "Init is idempotent:test_init_idempotent"

        # Ticket create
        "Ticket create basic:test_ticket_create_basic"
        "Ticket create with type:test_ticket_create_with_type"
        "Ticket create with priority:test_ticket_create_with_priority"
        "Ticket create initial state:test_ticket_create_initial_state"
        "Ticket create with dependency:test_ticket_create_with_dependency"
        "Ticket create has title:test_ticket_create_has_title"

        # Ticket list
        "Ticket list empty:test_ticket_list_empty"
        "Ticket list shows tickets:test_ticket_list_shows_tickets"
        "Ticket list filter by state:test_ticket_list_filter_by_state"
        "Ticket list filter by type:test_ticket_list_filter_by_type"

        # Ticket show
        "Ticket show displays content:test_ticket_show_displays_content"
        "Ticket show partial ID:test_ticket_show_partial_id"
        "Ticket show not found:test_ticket_show_not_found"

        # Ticket claim
        "Ticket claim:test_ticket_claim"
        "Ticket claim sets timestamp:test_ticket_claim_sets_timestamp"
        "Ticket claim already claimed:test_ticket_claim_already_claimed"

        # Ticket transition
        "Ticket transition valid:test_ticket_transition_valid"
        "Ticket transition full workflow:test_ticket_transition_full_workflow"
        "Ticket transition invalid:test_ticket_transition_invalid"
        "Ticket transition review rejection:test_ticket_transition_review_rejection"

        # Ticket ready/blocked
        "Ticket ready lists unblocked:test_ticket_ready_lists_unblocked"
        "Ticket ready excludes blocked:test_ticket_ready_excludes_blocked"
        "Ticket ready with limit:test_ticket_ready_with_limit"
        "Ticket blocked shows blockers:test_ticket_blocked_shows_blockers"

        # Ticket tree
        "Ticket tree shows deps:test_ticket_tree_shows_deps"

        # Ticket feedback
        "Ticket feedback appends:test_ticket_feedback_appends"
        "Ticket feedback multiple:test_ticket_feedback_multiple"

        # Utilities
        "Require project fails outside:test_require_project_fails_outside"
        "ID format:test_id_format"

        # Tmux session management
        "Tmux init creates session:test_init_creates_session"
        "Tmux init session idempotent:test_init_session_idempotent"
        "Tmux teardown kills session:test_teardown_kills_session"
        "Tmux list panes empty:test_list_panes_empty"
        "Tmux list panes json:test_list_panes_json_format"
        "Tmux status shows overview:test_status_shows_overview"
        "Tmux attach fails no session:test_attach_fails_no_session"
        "Tmux teardown fails no session:test_teardown_fails_no_session"
    )

    for test_entry in "${tests[@]}"; do
        local name="${test_entry%%:*}"
        local func="${test_entry##*:}"

        # Filter if requested
        if [[ -n "$filter" && "$name" != *"$filter"* && "$func" != *"$filter"* ]]; then
            continue
        fi

        run_test "$name" "$func"
    done

    echo ""
    echo "----------------------------------------"
    echo -e "Tests run: $TESTS_RUN"
    echo -e "Passed:    ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:    ${RED}$TESTS_FAILED${NC}"
    echo "----------------------------------------"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
