#!/bin/bash
#
# test_cli.sh - CLI basics tests
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests
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
# Test list
#

CLI_TESTS=(
    "CLI help:test_help"
    "CLI version:test_version"
    "CLI unknown command:test_unknown_command"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running CLI tests..."
    run_tests "${1:-}" CLI_TESTS
    print_summary
fi
