#!/bin/bash
#
# test_distributed.sh - Distributed tickets tests
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests
#

test_init_distributed_creates_bare_repo() {
    "$RALPHS_BIN" init --no-session --distributed
    assert_dir_exists ".ralphs/tickets.git" "Distributed init should create bare repo"
    assert_dir_exists ".ralphs/tickets.git/objects" "Bare repo should have objects dir"
}

test_init_distributed_has_pre_receive_hook() {
    "$RALPHS_BIN" init --no-session --distributed
    assert_file_exists ".ralphs/tickets.git/hooks/pre-receive" "Should install pre-receive hook"

    # Check it's executable
    if [[ ! -x ".ralphs/tickets.git/hooks/pre-receive" ]]; then
        echo "pre-receive hook should be executable"
        return 1
    fi
}

test_init_distributed_has_post_receive_hook() {
    "$RALPHS_BIN" init --no-session --distributed
    assert_file_exists ".ralphs/tickets.git/hooks/post-receive" "Should install post-receive hook"

    # Check it's executable
    if [[ ! -x ".ralphs/tickets.git/hooks/post-receive" ]]; then
        echo "post-receive hook should be executable"
        return 1
    fi
}

test_init_distributed_updates_gitignore() {
    "$RALPHS_BIN" init --no-session --distributed

    # Check .gitignore contains the expected entries
    assert_file_exists ".gitignore" ".gitignore should exist"

    local content
    content=$(cat .gitignore)
    assert_contains "$content" ".ralphs/tickets.git/" "Should ignore bare repo"
    assert_contains "$content" "worktrees/" "Should ignore worktrees"
}

test_init_distributed_creates_initial_commit() {
    "$RALPHS_BIN" init --no-session --distributed

    # Clone the bare repo and check for initial commit
    local tmp
    tmp=$(mktemp -d)
    git clone .ralphs/tickets.git "$tmp" --quiet 2>/dev/null

    local log
    log=$(git -C "$tmp" log --oneline 2>/dev/null)
    assert_contains "$log" "Initial commit" "Bare repo should have initial commit"

    rm -rf "$tmp"
}

test_is_distributed_false_without_bare_repo() {
    "$RALPHS_BIN" init --no-session

    # Check that is_distributed returns false
    # We do this by checking that the bare repo doesn't exist
    if [[ -d ".ralphs/tickets.git" ]]; then
        echo "Should not have bare repo without --distributed"
        return 1
    fi
}

test_ticket_sync_command_exists() {
    "$RALPHS_BIN" init --no-session --distributed

    local output
    output=$("$RALPHS_BIN" ticket sync 2>&1)

    # Should not fail with "Unknown subcommand"
    if [[ "$output" == *"Unknown subcommand"* ]]; then
        echo "ticket sync command should exist"
        return 1
    fi
}

test_ticket_create_in_distributed_mode() {
    "$RALPHS_BIN" init --no-session --distributed

    # Create a ticket with --no-sync to avoid sync issues in test
    local ticket_id
    ticket_id=$("$RALPHS_BIN" ticket create "Distributed test" --no-sync)

    assert_file_exists ".ralphs/tickets/${ticket_id}.md" "Ticket should be created"
}

test_distributed_tickets_have_merge_strategy() {
    "$RALPHS_BIN" init --no-session --distributed

    assert_file_exists ".ralphs/tickets.git/info/attributes" "Should have attributes file"

    local content
    content=$(cat .ralphs/tickets.git/info/attributes)
    assert_contains "$content" "*.md merge=union" "Should set union merge for markdown"
}

test_help_shows_distributed_flag() {
    local output
    output=$("$RALPHS_BIN" --help)
    assert_contains "$output" "--distributed" "Help should show --distributed flag"
}

test_help_shows_ticket_sync() {
    local output
    output=$("$RALPHS_BIN" --help)
    assert_contains "$output" "ticket sync" "Help should show ticket sync command"
}

#
# Test list
#

DISTRIBUTED_TESTS=(
    "Init distributed creates bare repo:test_init_distributed_creates_bare_repo"
    "Init distributed has pre-receive hook:test_init_distributed_has_pre_receive_hook"
    "Init distributed has post-receive hook:test_init_distributed_has_post_receive_hook"
    "Init distributed updates gitignore:test_init_distributed_updates_gitignore"
    "Init distributed creates initial commit:test_init_distributed_creates_initial_commit"
    "Is distributed false without bare repo:test_is_distributed_false_without_bare_repo"
    "Ticket sync command exists:test_ticket_sync_command_exists"
    "Ticket create in distributed mode:test_ticket_create_in_distributed_mode"
    "Distributed tickets have merge strategy:test_distributed_tickets_have_merge_strategy"
    "Help shows distributed flag:test_help_shows_distributed_flag"
    "Help shows ticket sync:test_help_shows_ticket_sync"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running distributed tests..."
    run_tests "${1:-}" DISTRIBUTED_TESTS
    print_summary
fi
