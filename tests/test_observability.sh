#!/bin/bash
#
# test_observability.sh - Observability tools tests (fetch, logs, digest)
#

# SC2034: Test arrays are used by main test runner via source
# SC2064: We intentionally expand variables at trap definition time
# shellcheck disable=SC2034,SC2064

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests
#

test_fetch_requires_pane_id() {
    "$WIGGUM_BIN" init

    # fetch without pane-id should fail
    if "$WIGGUM_BIN" fetch 2>/dev/null; then
        echo "Fetch should require pane-id argument"
        return 1
    fi
}

test_fetch_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$WIGGUM_BIN" init

    # fetch with no session should fail
    if "$WIGGUM_BIN" fetch worker-0 2>/dev/null; then
        echo "Fetch should fail without session"
        return 1
    fi
}

test_fetch_pane_not_found() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export WIGGUM_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" spawn supervisor &>/dev/null

    # fetch non-existent pane should fail
    if "$WIGGUM_BIN" fetch nonexistent-pane 2>/dev/null; then
        echo "Fetch should fail for non-existent pane"
        return 1
    fi

    cleanup_test_session "$session"
}

test_logs_requires_pane_id() {
    "$WIGGUM_BIN" init

    # logs without pane-id should fail
    if "$WIGGUM_BIN" logs 2>/dev/null; then
        echo "Logs should require pane-id argument"
        return 1
    fi
}

test_logs_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$WIGGUM_BIN" init

    # logs with no session should fail
    if "$WIGGUM_BIN" logs worker-0 2>/dev/null; then
        echo "Logs should fail without session"
        return 1
    fi
}

test_digest_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$WIGGUM_BIN" init

    # digest with no session should fail
    if "$WIGGUM_BIN" digest 2>/dev/null; then
        echo "Digest should fail without session"
        return 1
    fi
}

#
# Test list
#

OBSERVABILITY_TESTS=(
    "Fetch requires pane-id:test_fetch_requires_pane_id"
    "Fetch fails no session:test_fetch_fails_no_session"
    "Fetch pane not found:test_fetch_pane_not_found"
    "Logs requires pane-id:test_logs_requires_pane_id"
    "Logs fails no session:test_logs_fails_no_session"
    "Digest fails no session:test_digest_fails_no_session"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running observability tests..."
    run_tests "${1:-}" OBSERVABILITY_TESTS
    print_summary
fi
