#!/bin/bash
#
# test_hooks_transition.sh - Tests for hook invocation from ticket transition
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Tests: Hook invocation from transition
#

test_transition_invokes_post_hooks() {
    "$WIGGUM_BIN" init

    # Create a test hook that creates a marker file
    cat > ".wiggum/hooks/on-claim" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-on-claim-ran"
HOOK
    chmod +x ".wiggum/hooks/on-claim"

    # Create and transition a ticket
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test hook invocation")

    # Transition ready -> in-progress (should trigger on-claim)
    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress

    # Wait briefly for background hook
    sleep 0.5

    assert_file_exists ".hook-on-claim-ran" "on-claim hook should have created marker file"
}

test_transition_no_hooks_flag() {
    "$WIGGUM_BIN" init

    # Create a test hook that creates a marker file
    cat > ".wiggum/hooks/on-claim" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-should-not-run"
HOOK
    chmod +x ".wiggum/hooks/on-claim"

    # Create and transition a ticket with --no-hooks
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test no hooks")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks

    # Wait briefly in case hook runs
    sleep 0.5

    # Marker file should NOT exist
    if [[ -f ".hook-should-not-run" ]]; then
        echo "Hook should not have run with --no-hooks flag"
        return 1
    fi
}

test_transition_hook_receives_state_info() {
    "$WIGGUM_BIN" init

    # Create a test hook that records state info
    cat > ".wiggum/hooks/on-claim" << 'HOOK'
#!/bin/bash
echo "PREV=$WIGGUM_PREV_STATE NEW=$WIGGUM_NEW_STATE" > "$MAIN_PROJECT_ROOT/.hook-state-info"
HOOK
    chmod +x ".wiggum/hooks/on-claim"

    # Create and transition a ticket
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test state info")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress

    # Wait for hook
    sleep 0.5

    assert_file_exists ".hook-state-info" "Hook should have recorded state info"

    local content
    content=$(cat ".hook-state-info")
    assert_contains "$content" "PREV=ready" "Should have previous state"
    assert_contains "$content" "NEW=in-progress" "Should have new state"
}

test_transition_draft_done_hook() {
    "$WIGGUM_BIN" init

    # Create a test hook
    cat > ".wiggum/hooks/on-draft-done" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-draft-done-ran"
HOOK
    chmod +x ".wiggum/hooks/on-draft-done"

    # Create and transition a ticket through to review
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test draft done")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" review

    # Wait for hook
    sleep 0.5

    assert_file_exists ".hook-draft-done-ran" "on-draft-done hook should have run"
}

test_transition_review_done_hook() {
    "$WIGGUM_BIN" init

    # Create a test hook
    cat > ".wiggum/hooks/on-review-done" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-review-done-ran"
HOOK
    chmod +x ".wiggum/hooks/on-review-done"

    # Create and transition a ticket through to QA
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test review done")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" review --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" qa

    # Wait for hook
    sleep 0.5

    assert_file_exists ".hook-review-done-ran" "on-review-done hook should have run"
}

test_transition_rejection_hook() {
    "$WIGGUM_BIN" init

    # Create a test hook for rejection
    cat > ".wiggum/hooks/on-review-rejected" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-review-rejected-ran"
HOOK
    chmod +x ".wiggum/hooks/on-review-rejected"

    # Create and transition a ticket to review then reject
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test rejection")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" review --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress  # Rejection!

    # Wait for hook
    sleep 0.5

    assert_file_exists ".hook-review-rejected-ran" "on-review-rejected hook should have run"
}

test_transition_qa_done_hook() {
    "$WIGGUM_BIN" init

    # Create test hooks
    cat > ".wiggum/hooks/on-qa-done" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-qa-done-ran"
HOOK
    chmod +x ".wiggum/hooks/on-qa-done"

    cat > ".wiggum/hooks/on-close" << 'HOOK'
#!/bin/bash
touch "$MAIN_PROJECT_ROOT/.hook-close-ran"
HOOK
    chmod +x ".wiggum/hooks/on-close"

    # Create and transition a ticket through to done
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test QA done")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" review --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" qa --no-hooks
    "$WIGGUM_BIN" ticket transition "$ticket_id" done

    # Wait for hooks
    sleep 0.5

    assert_file_exists ".hook-qa-done-ran" "on-qa-done hook should have run"
    assert_file_exists ".hook-close-ran" "on-close hook should have run"
}

#
# Tests: Pre-transition hooks
#

test_pre_transition_hook_can_block() {
    "$WIGGUM_BIN" init

    # Configure a pre-transition hook
    cat > ".wiggum/ticket_types.json" << 'EOF'
{
  "states": ["ready", "in-progress", "review", "qa", "done", "closed"],
  "transitions": {
    "ready": {
      "targets": ["in-progress", "closed"],
      "hooks": { "pre": [], "post": { "in-progress": ["on-claim"] } }
    },
    "in-progress": {
      "targets": ["review"],
      "hooks": {
        "pre": { "review": ["pre-review"] },
        "post": { "review": ["on-draft-done"] }
      }
    },
    "review": {
      "targets": ["qa", "in-progress", "done", "closed"],
      "hooks": { "pre": [], "post": {} }
    },
    "qa": {
      "targets": ["done", "in-progress", "closed"],
      "hooks": { "pre": [], "post": {} }
    },
    "done": { "targets": [], "hooks": { "pre": [], "post": {} } },
    "closed": { "targets": [], "hooks": { "pre": [], "post": {} } }
  },
  "default_type": "task",
  "types": ["feature", "bug", "task"]
}
EOF

    # Create a pre-hook that fails
    cat > ".wiggum/hooks/pre-review" << 'HOOK'
#!/bin/bash
echo "Pre-review check failed!"
exit 1
HOOK
    chmod +x ".wiggum/hooks/pre-review"

    # Create and try to transition a ticket
    local ticket_id
    ticket_id=$("$WIGGUM_BIN" ticket create "Test pre-hook block")

    "$WIGGUM_BIN" ticket transition "$ticket_id" in-progress --no-hooks

    # This should fail due to pre-hook
    if "$WIGGUM_BIN" ticket transition "$ticket_id" review 2>/dev/null; then
        echo "Transition should have been blocked by pre-hook"
        return 1
    fi

    # Verify ticket is still in-progress
    local state
    state=$("$WIGGUM_BIN" ticket show "$ticket_id" | grep "^state:" | awk '{print $2}')
    assert_eq "in-progress" "$state" "Ticket should still be in-progress after pre-hook block"
}

#
# Test list
#

HOOKS_TRANSITION_TESTS=(
    # Post-hook invocation
    "Transition invokes post hooks:test_transition_invokes_post_hooks"
    "Transition --no-hooks flag:test_transition_no_hooks_flag"
    "Transition hook receives state info:test_transition_hook_receives_state_info"
    "Transition draft done hook:test_transition_draft_done_hook"
    "Transition review done hook:test_transition_review_done_hook"
    "Transition rejection hook:test_transition_rejection_hook"
    "Transition qa done hook:test_transition_qa_done_hook"

    # Pre-hook invocation
    "Pre-transition hook can block:test_pre_transition_hook_can_block"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running hooks transition tests..."
    run_tests "${1:-}" HOOKS_TRANSITION_TESTS
    print_summary
fi
