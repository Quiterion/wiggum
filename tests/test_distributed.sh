#!/bin/bash
#
# test_distributed.sh - Distributed tickets tests
#
# Tests the git-based ticket synchronization system.
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests
#

test_init_creates_bare_repo() {
    "$WIGGUM_BIN" init
    assert_dir_exists ".wiggum/tickets.git" "Init should create bare repo"
    assert_dir_exists ".wiggum/tickets.git/objects" "Bare repo should have objects dir"
}

test_init_creates_tickets_clone() {
    "$WIGGUM_BIN" init
    assert_dir_exists ".wiggum/tickets" "Init should create tickets clone"
    assert_dir_exists ".wiggum/tickets/.git" "Tickets dir should be a git clone"
}

# NOTE: Bare repo hooks have been removed as part of the ticket refactor.
# Validation and hook invocation now happens directly in ticket_transition().
# These test functions are kept as no-ops for backwards compatibility.

test_init_no_bare_repo_hooks() {
    "$WIGGUM_BIN" init

    # Verify hooks are NOT installed (they've been removed)
    if [[ -f ".wiggum/tickets.git/hooks/pre-receive" ]]; then
        echo "pre-receive hook should NOT be installed (deprecated)"
        return 1
    fi
    if [[ -f ".wiggum/tickets.git/hooks/post-receive" ]]; then
        echo "post-receive hook should NOT be installed (deprecated)"
        return 1
    fi
}

test_init_updates_gitignore() {
    "$WIGGUM_BIN" init

    assert_file_exists ".gitignore" ".gitignore should exist"

    local content
    content=$(cat .gitignore)
    # .wiggum/ is ignored as a directory (includes tickets.git and tickets)
    assert_contains "$content" ".wiggum/" "Should ignore wiggum directory"
    assert_contains "$content" "worktrees/" "Should ignore worktrees"
}

test_init_creates_initial_commit() {
    "$WIGGUM_BIN" init

    # Check local clone has initial commit
    local log
    log=$(git -C .wiggum/tickets log --oneline 2>/dev/null)
    assert_contains "$log" "Initial commit" "Tickets clone should have initial commit"
}

test_ticket_sync_command_exists() {
    "$WIGGUM_BIN" init

    local output
    output=$("$WIGGUM_BIN" ticket sync 2>&1)

    # Should not fail with "Unknown subcommand"
    if [[ "$output" == *"Unknown subcommand"* ]]; then
        echo "ticket sync command should exist"
        return 1
    fi
}

test_ticket_create_syncs_to_repo() {
    "$WIGGUM_BIN" init

    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Sync test")

    # Ticket should exist in local clone
    assert_file_exists ".wiggum/tickets/${ticket_id}.md" "Ticket should be created in clone"

    # Check if commit was pushed to bare repo
    local log
    log=$(git -C .wiggum/tickets.git log --oneline 2>/dev/null || echo "")
    assert_contains "$log" "Create ticket" "Ticket creation should be pushed to bare repo"
}

test_tickets_have_merge_strategy() {
    "$WIGGUM_BIN" init

    assert_file_exists ".wiggum/tickets.git/info/attributes" "Should have attributes file"

    local content
    content=$(cat .wiggum/tickets.git/info/attributes)
    assert_contains "$content" "*.md merge=union" "Should set union merge for markdown"
}

test_help_shows_ticket_sync() {
    local output
    output=$("$WIGGUM_BIN" --help)
    assert_contains "$output" "ticket sync" "Help should show ticket sync command"
}

#
# Test list
#

DISTRIBUTED_TESTS=(
    "Init creates bare repo:test_init_creates_bare_repo"
    "Init creates tickets clone:test_init_creates_tickets_clone"
    "Init no bare repo hooks:test_init_no_bare_repo_hooks"
    "Init updates gitignore:test_init_updates_gitignore"
    "Init creates initial commit:test_init_creates_initial_commit"
    "Ticket sync command exists:test_ticket_sync_command_exists"
    "Ticket create syncs to repo:test_ticket_create_syncs_to_repo"
    "Tickets have merge strategy:test_tickets_have_merge_strategy"
    "Help shows ticket sync:test_help_shows_ticket_sync"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running distributed tests..."
    run_tests "${1:-}" DISTRIBUTED_TESTS
    print_summary
fi
