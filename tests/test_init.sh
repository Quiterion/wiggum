#!/bin/bash
#
# test_init.sh - Init command tests
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests
#

test_init_creates_ralphs_dir() {
    "$RALPHS_BIN" init
    assert_dir_exists ".ralphs" "Init should create .ralphs directory"
}

test_init_creates_config() {
    "$RALPHS_BIN" init
    assert_file_exists ".ralphs/config.sh" "Init should create config.sh"
}

test_init_creates_tickets_dir() {
    "$RALPHS_BIN" init
    assert_dir_exists ".ralphs/tickets" "Init should create tickets directory"
}

test_init_creates_hooks_dir() {
    "$RALPHS_BIN" init
    assert_dir_exists ".ralphs/hooks" "Init should create hooks directory"
}

test_init_creates_prompts_dir() {
    "$RALPHS_BIN" init
    assert_dir_exists ".ralphs/prompts" "Init should create prompts directory"
}

test_init_copies_default_hooks() {
    "$RALPHS_BIN" init
    assert_file_exists ".ralphs/hooks/on-claim" "Init should copy on-claim hook"
    assert_file_exists ".ralphs/hooks/on-in-progress-done" "Init should copy on-in-progress-done hook"
}

test_init_copies_default_prompts() {
    "$RALPHS_BIN" init
    assert_file_exists ".ralphs/prompts/supervisor.md" "Init should copy supervisor prompt"
    assert_file_exists ".ralphs/prompts/worker.md" "Init should copy worker prompt"
}

test_init_idempotent() {
    "$RALPHS_BIN" init
    "$RALPHS_BIN" init  # Should not fail
    assert_dir_exists ".ralphs"
}

test_init_from_subdirectory() {
    # Init from subdirectory should create .ralphs at git root
    mkdir -p src/deep/nested
    cd src/deep/nested || exit 1
    "$RALPHS_BIN" init
    # .ralphs should be at git root, not in subdirectory
    assert_dir_exists "../../../.ralphs" "Init from subdir should create .ralphs at git root"
    assert_not_exists ".ralphs" "Init from subdir should NOT create .ralphs in subdir"
}

test_init_from_tickets_clone() {
    # Init from inside .ralphs/tickets should use existing project
    "$RALPHS_BIN" init
    cd .ralphs/tickets || exit 1
    "$RALPHS_BIN" init
    # Should not create nested .ralphs
    assert_not_exists ".ralphs" "Init from tickets clone should NOT create nested .ralphs"
}

test_commands_from_subdirectory() {
    # Commands should work from subdirectories
    "$RALPHS_BIN" init
    mkdir -p src/deep
    cd src/deep || exit 1
    local id
    id=$("$RALPHS_BIN" ticket create "From subdir")
    # Ticket should be created at project root
    assert_file_exists "../../.ralphs/tickets/${id}.md" "Ticket should be created at project root"
}

#
# Test list
#

INIT_TESTS=(
    "Init creates .ralphs:test_init_creates_ralphs_dir"
    "Init creates config:test_init_creates_config"
    "Init creates tickets dir:test_init_creates_tickets_dir"
    "Init creates hooks dir:test_init_creates_hooks_dir"
    "Init creates prompts dir:test_init_creates_prompts_dir"
    "Init copies default hooks:test_init_copies_default_hooks"
    "Init copies default prompts:test_init_copies_default_prompts"
    "Init is idempotent:test_init_idempotent"
    "Init from subdirectory:test_init_from_subdirectory"
    "Init from tickets clone:test_init_from_tickets_clone"
    "Commands from subdirectory:test_commands_from_subdirectory"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running init tests..."
    run_tests "${1:-}" INIT_TESTS
    print_summary
fi
