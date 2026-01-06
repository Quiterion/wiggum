#!/bin/bash
#
# test_ticket_types.sh - Tests for ticket type configuration
#

# SC2034: Test arrays are used by main test runner via source
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

#
# Helper to source wiggum libs
#
source_wiggum_libs() {
    local wiggum_root
    wiggum_root="$(dirname "$WIGGUM_BIN")/.."
    export WIGGUM_DEFAULTS="$wiggum_root/defaults"

    # Initialize global flags required by utils.sh
    export WIGGUM_VERBOSE="${WIGGUM_VERBOSE:-false}"
    export WIGGUM_QUIET="${WIGGUM_QUIET:-false}"

    # shellcheck disable=SC1091
    source "$wiggum_root/lib/config.sh"
    # shellcheck disable=SC1091
    source "$wiggum_root/lib/utils.sh"
    # shellcheck disable=SC1091
    source "$wiggum_root/lib/ticket_types.sh"
}

#
# Tests: get_valid_states
#

test_get_valid_states_default() {
    source_wiggum_libs
    reset_ticket_types_cache

    local states
    states=$(get_valid_states)

    assert_contains "$states" "ready" "Should have ready state"
    assert_contains "$states" "in-progress" "Should have in-progress state"
    assert_contains "$states" "review" "Should have review state"
    assert_contains "$states" "qa" "Should have qa state"
    assert_contains "$states" "done" "Should have done state"
    assert_contains "$states" "closed" "Should have closed state"
}

test_get_valid_states_from_config() {
    "$WIGGUM_BIN" init

    source_wiggum_libs
    reset_ticket_types_cache
    PROJECT_ROOT="$(pwd)"
    MAIN_WIGGUM_DIR="$PROJECT_ROOT/.wiggum"

    # Verify default config was copied
    assert_file_exists ".wiggum/ticket_types.json" "ticket_types.json should exist"

    local states
    states=$(get_valid_states)

    assert_contains "$states" "ready" "Should have ready state from config"
    assert_contains "$states" "done" "Should have done state from config"
}

#
# Tests: get_valid_transitions
#

test_get_valid_transitions_from_ready() {
    source_wiggum_libs
    reset_ticket_types_cache

    local targets
    targets=$(get_valid_transitions "ready")

    assert_contains "$targets" "in-progress" "Should allow ready -> in-progress"
    assert_contains "$targets" "closed" "Should allow ready -> closed"
}

test_get_valid_transitions_from_in_progress() {
    source_wiggum_libs
    reset_ticket_types_cache

    local targets
    targets=$(get_valid_transitions "in-progress")

    assert_contains "$targets" "review" "Should allow in-progress -> review"
}

test_get_valid_transitions_from_review() {
    source_wiggum_libs
    reset_ticket_types_cache

    local targets
    targets=$(get_valid_transitions "review")

    assert_contains "$targets" "qa" "Should allow review -> qa"
    assert_contains "$targets" "in-progress" "Should allow review -> in-progress (rejection)"
    assert_contains "$targets" "done" "Should allow review -> done"
}

test_get_valid_transitions_from_qa() {
    source_wiggum_libs
    reset_ticket_types_cache

    local targets
    targets=$(get_valid_transitions "qa")

    assert_contains "$targets" "done" "Should allow qa -> done"
    assert_contains "$targets" "in-progress" "Should allow qa -> in-progress (rejection)"
}

test_get_valid_transitions_from_done() {
    source_wiggum_libs
    reset_ticket_types_cache

    local targets
    targets=$(get_valid_transitions "done")

    # done is terminal state
    assert_eq "" "$targets" "Should have no transitions from done"
}

#
# Tests: is_valid_transition
#

test_is_valid_transition_allowed() {
    source_wiggum_libs
    reset_ticket_types_cache

    if ! is_valid_transition "ready" "in-progress"; then
        echo "ready -> in-progress should be valid"
        return 1
    fi

    if ! is_valid_transition "in-progress" "review"; then
        echo "in-progress -> review should be valid"
        return 1
    fi

    if ! is_valid_transition "review" "qa"; then
        echo "review -> qa should be valid"
        return 1
    fi
}

test_is_valid_transition_rejected() {
    source_wiggum_libs
    reset_ticket_types_cache

    if is_valid_transition "ready" "done"; then
        echo "ready -> done should NOT be valid"
        return 1
    fi

    if is_valid_transition "in-progress" "ready"; then
        echo "in-progress -> ready should NOT be valid"
        return 1
    fi
}

#
# Tests: get_transition_hooks
#

test_get_transition_hooks_post() {
    "$WIGGUM_BIN" init

    source_wiggum_libs
    reset_ticket_types_cache
    PROJECT_ROOT="$(pwd)"
    MAIN_WIGGUM_DIR="$PROJECT_ROOT/.wiggum"

    local hooks
    hooks=$(get_transition_hooks "ready" "in-progress" "post")
    assert_contains "$hooks" "on-claim" "Should have on-claim hook for ready -> in-progress"

    hooks=$(get_transition_hooks "in-progress" "review" "post")
    assert_contains "$hooks" "on-draft-done" "Should have on-draft-done hook for in-progress -> review"

    hooks=$(get_transition_hooks "review" "qa" "post")
    assert_contains "$hooks" "on-review-done" "Should have on-review-done hook for review -> qa"
}

test_get_transition_hooks_rejection() {
    "$WIGGUM_BIN" init

    source_wiggum_libs
    reset_ticket_types_cache
    PROJECT_ROOT="$(pwd)"
    MAIN_WIGGUM_DIR="$PROJECT_ROOT/.wiggum"

    local hooks
    hooks=$(get_transition_hooks "review" "in-progress" "post")
    assert_contains "$hooks" "on-review-rejected" "Should have on-review-rejected hook"

    hooks=$(get_transition_hooks "qa" "in-progress" "post")
    assert_contains "$hooks" "on-qa-rejected" "Should have on-qa-rejected hook"
}

#
# Tests: Custom configuration
#

test_custom_ticket_types_config() {
    "$WIGGUM_BIN" init

    # Create custom config with different states
    cat > ".wiggum/ticket_types.json" << 'EOF'
{
  "states": ["new", "working", "complete"],
  "transitions": {
    "new": {
      "targets": ["working"],
      "hooks": { "pre": [], "post": {} }
    },
    "working": {
      "targets": ["complete"],
      "hooks": { "pre": [], "post": {} }
    },
    "complete": {
      "targets": [],
      "hooks": { "pre": [], "post": {} }
    }
  },
  "default_type": "task",
  "types": ["task"]
}
EOF

    source_wiggum_libs
    reset_ticket_types_cache
    PROJECT_ROOT="$(pwd)"
    MAIN_WIGGUM_DIR="$PROJECT_ROOT/.wiggum"

    local states
    states=$(get_valid_states)

    assert_contains "$states" "new" "Should have custom 'new' state"
    assert_contains "$states" "working" "Should have custom 'working' state"
    assert_contains "$states" "complete" "Should have custom 'complete' state"

    # Check transitions
    local targets
    targets=$(get_valid_transitions "new")
    assert_contains "$targets" "working" "Should allow new -> working"

    targets=$(get_valid_transitions "working")
    assert_contains "$targets" "complete" "Should allow working -> complete"
}

#
# Tests: Fallback behavior
#

test_fallback_without_jq() {
    source_wiggum_libs
    reset_ticket_types_cache

    # Temporarily override jq check
    local original_config="$_TICKET_TYPES_CONFIG"
    _TICKET_TYPES_CONFIG=""

    # Force fallback by clearing config
    local states
    states=$(get_valid_states)

    assert_contains "$states" "ready" "Fallback should have ready state"
    assert_contains "$states" "in-progress" "Fallback should have in-progress state"

    # Restore
    _TICKET_TYPES_CONFIG="$original_config"
}

#
# Tests: get_valid_ticket_types
#

test_get_valid_ticket_types() {
    source_wiggum_libs
    reset_ticket_types_cache

    local types
    types=$(get_valid_ticket_types)

    assert_contains "$types" "feature" "Should have feature type"
    assert_contains "$types" "bug" "Should have bug type"
    assert_contains "$types" "task" "Should have task type"
}

test_get_default_ticket_type() {
    source_wiggum_libs
    reset_ticket_types_cache

    local default_type
    default_type=$(get_default_ticket_type)

    assert_eq "task" "$default_type" "Default type should be task"
}

#
# Test list
#

TICKET_TYPES_TESTS=(
    # get_valid_states
    "get_valid_states default:test_get_valid_states_default"
    "get_valid_states from config:test_get_valid_states_from_config"

    # get_valid_transitions
    "get_valid_transitions from ready:test_get_valid_transitions_from_ready"
    "get_valid_transitions from in-progress:test_get_valid_transitions_from_in_progress"
    "get_valid_transitions from review:test_get_valid_transitions_from_review"
    "get_valid_transitions from qa:test_get_valid_transitions_from_qa"
    "get_valid_transitions from done:test_get_valid_transitions_from_done"

    # is_valid_transition
    "is_valid_transition allowed:test_is_valid_transition_allowed"
    "is_valid_transition rejected:test_is_valid_transition_rejected"

    # get_transition_hooks
    "get_transition_hooks post:test_get_transition_hooks_post"
    "get_transition_hooks rejection:test_get_transition_hooks_rejection"

    # Custom configuration
    "Custom ticket types config:test_custom_ticket_types_config"

    # Fallback
    "Fallback without jq:test_fallback_without_jq"

    # Ticket types
    "get_valid_ticket_types:test_get_valid_ticket_types"
    "get_default_ticket_type:test_get_default_ticket_type"
)

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    trap teardown EXIT
    echo "Running ticket types tests..."
    run_tests "${1:-}" TICKET_TYPES_TESTS
    print_summary
fi
