#!/bin/bash
#
# test_tmux.sh - Tmux session management tests
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

test_spawn_creates_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export WIGGUM_SESSION="$session"

    # Ensure cleanup on exit
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init

    # Session should NOT exist after init (lazy creation)
    if tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should NOT exist after init"
        return 1
    fi

    # Spawn supervisor should create session
    "$WIGGUM_BIN" spawn supervisor &>/dev/null

    # Verify session exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should exist after spawn"
        return 1
    fi

    # Cleanup
    cleanup_test_session "$session"
}

test_spawn_session_idempotent() {
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

    # Create a ticket for second spawn
    "$WIGGUM_BIN" ticket create "Test ticket" &>/dev/null
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket ready | head -1)

    # Second spawn should not fail
    if [[ -n "$ticket_id" ]]; then
        "$WIGGUM_BIN" spawn worker "$ticket_id" &>/dev/null
    fi

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
    export WIGGUM_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" spawn supervisor &>/dev/null

    # Verify it exists
    if ! tmux has-session -t "$session" 2>/dev/null; then
        echo "Session should exist before teardown"
        return 1
    fi

    "$WIGGUM_BIN" teardown --force

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
    export WIGGUM_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init

    local output
    output=$("$WIGGUM_BIN" list)

    # Should show table headers at minimum (even without session)
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
    export WIGGUM_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" spawn supervisor &>/dev/null

    local output
    output=$("$WIGGUM_BIN" list --format json)

    # Should be valid JSON object
    if [[ "$output" != "{}" && "$output" != *"{"* ]]; then
        echo "JSON format should return object, got: $output"
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
    export WIGGUM_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init
    "$WIGGUM_BIN" ticket create "Status test ticket"

    local output
    output=$("$WIGGUM_BIN" status)

    # Should show session and ticket info
    assert_contains "$output" "SESSION:" "Should show session info"
    assert_contains "$output" "TICKETS:" "Should show ticket count"

    cleanup_test_session "$session"
}

test_attach_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$WIGGUM_BIN" init

    # Try to attach to non-existent session
    if "$WIGGUM_BIN" attach 2>/dev/null; then
        echo "Attach should fail for non-existent session"
        return 1
    fi
}

test_teardown_fails_no_session() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    "$WIGGUM_BIN" init

    # Try to teardown non-existent session
    if "$WIGGUM_BIN" teardown 2>/dev/null; then
        echo "Teardown should fail for non-existent session"
        return 1
    fi
}

test_send_keys_requires_args() {
    if ! tmux_available; then
        echo "SKIP:tmux not available"
        return 0
    fi

    local session
    session=$(test_session_name)
    export WIGGUM_SESSION="$session"
    trap "cleanup_test_session '$session'" RETURN

    "$WIGGUM_BIN" init

    # send-keys with no args should fail
    if "$WIGGUM_BIN" send-keys 2>/dev/null; then
        echo "send-keys should require agent-id and keys"
        return 1
    fi

    # send-keys with only agent-id should fail
    if "$WIGGUM_BIN" send-keys worker-0 2>/dev/null; then
        echo "send-keys should require keys argument"
        return 1
    fi
}

test_send_keys_agent_not_found() {
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

    # send-keys to non-existent agent should fail
    if "$WIGGUM_BIN" send-keys nonexistent-0 "test keys" 2>/dev/null; then
        echo "send-keys should fail for non-existent agent"
        return 1
    fi

    cleanup_test_session "$session"
}

test_send_keys_to_agent() {
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

    # send-keys to supervisor should succeed
    local output
    if ! output=$("$WIGGUM_BIN" send-keys supervisor-0 "test keys" 2>&1); then
        echo "send-keys should succeed for existing agent"
        echo "Output: $output"
        return 1
    fi

    assert_contains "$output" "Sent keys" "Should show success message"

    cleanup_test_session "$session"
}

#
# Test list
#

TMUX_TESTS=(
    "Tmux spawn creates session:test_spawn_creates_session"
    "Tmux spawn session idempotent:test_spawn_session_idempotent"
    "Tmux teardown kills session:test_teardown_kills_session"
    "Tmux list panes empty:test_list_panes_empty"
    "Tmux list panes json:test_list_panes_json_format"
    "Tmux status shows overview:test_status_shows_overview"
    "Tmux attach fails no session:test_attach_fails_no_session"
    "Tmux teardown fails no session:test_teardown_fails_no_session"
    "Tmux send-keys requires args:test_send_keys_requires_args"
    "Tmux send-keys agent not found:test_send_keys_agent_not_found"
    "Tmux send-keys to agent:test_send_keys_to_agent"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running tmux tests..."
    run_tests "${1:-}" TMUX_TESTS
    print_summary
fi
