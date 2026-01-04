#!/bin/bash
#
# framework.sh - Test framework for ralphs
#
# Provides setup, teardown, assertions, and test running infrastructure.
#

# SC2064: We intentionally expand variables at trap definition time
# shellcheck disable=SC2064

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Test counters (global across all test files)
export TESTS_RUN="${TESTS_RUN:-0}"
export TESTS_PASSED="${TESTS_PASSED:-0}"
export TESTS_FAILED="${TESTS_FAILED:-0}"

# Test directory (cleaned up on exit)
TEST_DIR=""

# Ralphs binary (resolved at script load time, before any cd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RALPHS_BIN="$SCRIPT_DIR/../bin/ralphs"
export RALPHS_BIN

#
# Setup and teardown
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

#
# Test runner
#

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
            echo -e "${YELLOW}SKIP${NC} (${output#SKIP:})"
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

run_tests() {
    local filter="${1:-}"
    local -n test_array="$2"

    for test_entry in "${test_array[@]}"; do
        local name="${test_entry%%:*}"
        local func="${test_entry##*:}"

        # Filter if requested
        if [[ -n "$filter" && "$name" != *"$filter"* && "$func" != *"$filter"* ]]; then
            continue
        fi

        run_test "$name" "$func"
    done
}

#
# Assertions
#

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
# Tmux helpers
#

tmux_available() {
    command -v tmux &>/dev/null
}

test_session_name() {
    echo "ralphs-test-$$-$RANDOM"
}

cleanup_test_session() {
    local session="$1"
    tmux kill-session -t "$session" 2>/dev/null || true
}

#
# Summary printing
#

print_summary() {
    echo ""
    echo "----------------------------------------"
    echo -e "Tests run: $TESTS_RUN"
    echo -e "Passed:    ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:    ${RED}$TESTS_FAILED${NC}"
    echo "----------------------------------------"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        return 1
    fi
}
