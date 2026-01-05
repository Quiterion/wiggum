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

test_init_creates_wiggum_dir() {
    "$WIGGUM_BIN" init
    assert_dir_exists ".wiggum" "Init should create .wiggum directory"
}

test_init_creates_config() {
    "$WIGGUM_BIN" init
    assert_file_exists ".wiggum/config.sh" "Init should create config.sh"
}

test_init_creates_tickets_dir() {
    "$WIGGUM_BIN" init
    assert_dir_exists ".wiggum/tickets" "Init should create tickets directory"
}

test_init_creates_hooks_dir() {
    "$WIGGUM_BIN" init
    assert_dir_exists ".wiggum/hooks" "Init should create hooks directory"
}

test_init_creates_prompts_dir() {
    "$WIGGUM_BIN" init
    assert_dir_exists ".wiggum/prompts" "Init should create prompts directory"
}

test_init_copies_default_hooks() {
    "$WIGGUM_BIN" init
    assert_file_exists ".wiggum/hooks/on-claim" "Init should copy on-claim hook"
    assert_file_exists ".wiggum/hooks/on-draft-done" "Init should copy on-draft-done hook"
}

test_init_copies_default_prompts() {
    "$WIGGUM_BIN" init
    assert_file_exists ".wiggum/prompts/supervisor.md" "Init should copy supervisor prompt"
    assert_file_exists ".wiggum/prompts/worker.md" "Init should copy worker prompt"
}

test_init_idempotent() {
    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" init  # Should not fail
    assert_dir_exists ".wiggum"
}

test_init_from_subdirectory() {
    # Init from subdirectory should create .wiggum at git root
    mkdir -p src/deep/nested
    cd src/deep/nested || exit 1
    "$WIGGUM_BIN" init
    # .wiggum should be at git root, not in subdirectory
    assert_dir_exists "../../../.wiggum" "Init from subdir should create .wiggum at git root"
    assert_not_exists ".wiggum" "Init from subdir should NOT create .wiggum in subdir"
}

test_init_from_tickets_clone() {
    # Init from inside .wiggum/tickets should use existing project
    "$WIGGUM_BIN" init
    cd .wiggum/tickets || exit 1
    "$WIGGUM_BIN" init
    # Should not create nested .wiggum
    assert_not_exists ".wiggum" "Init from tickets clone should NOT create nested .wiggum"
}

test_commands_from_subdirectory() {
    # Commands should work from subdirectories
    "$WIGGUM_BIN" init
    mkdir -p src/deep
    cd src/deep || exit 1
    local id
    id=$("$WIGGUM_BIN" ticket create "From subdir")
    # Ticket should be created at project root
    assert_file_exists "../../.wiggum/tickets/${id}.md" "Ticket should be created at project root"
}

test_init_creates_claude_dir_when_agent_is_claude() {
    export WIGGUM_AGENT_CMD="claude"
    "$WIGGUM_BIN" init
    assert_dir_exists ".claude" "Init should create .claude directory when agent is claude"
    assert_file_exists ".claude/settings.local.json" "Init should create claude settings when agent is claude"
}

test_init_does_not_create_claude_dir_when_agent_is_not_claude() {
    export WIGGUM_AGENT_CMD="not-claude"
    "$WIGGUM_BIN" init
    assert_not_exists ".claude" "Init should NOT create .claude directory when agent is not claude"
}

#
# Test list
#

INIT_TESTS=(
    "Init creates .wiggum:test_init_creates_wiggum_dir"
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
    "Creates .claude when agent is claude:test_init_creates_claude_dir_when_agent_is_claude"
    "Does not create .claude when agent is not claude:test_init_does_not_create_claude_dir_when_agent_is_not_claude"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running init tests..."
    run_tests "${1:-}" INIT_TESTS
    print_summary
fi
