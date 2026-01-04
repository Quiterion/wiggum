#!/bin/bash
#
# test_ralphs.sh - Main test runner for ralphs CLI
#
# Usage:
#   ./tests/test_ralphs.sh           # Run all tests
#   ./tests/test_ralphs.sh [filter]  # Run tests matching filter
#   ./tests/test_ralphs.sh cli       # Run only CLI tests
#   ./tests/test_ralphs.sh ticket    # Run only ticket tests
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the framework
# shellcheck source=framework.sh
source "$SCRIPT_DIR/framework.sh"

# Source all test files (defines test functions and arrays)
# shellcheck source=test_cli.sh
source "$SCRIPT_DIR/test_cli.sh"
# shellcheck source=test_init.sh
source "$SCRIPT_DIR/test_init.sh"
# shellcheck source=test_ticket.sh
source "$SCRIPT_DIR/test_ticket.sh"
# shellcheck source=test_tmux.sh
source "$SCRIPT_DIR/test_tmux.sh"
# shellcheck source=test_observability.sh
source "$SCRIPT_DIR/test_observability.sh"
# shellcheck source=test_distributed.sh
source "$SCRIPT_DIR/test_distributed.sh"

#
# Main
#

main() {
    local filter="${1:-}"

    echo ""
    echo "Running ralphs tests..."
    echo ""

    # Set up exit trap
    trap teardown EXIT

    # Run all test suites
    echo "CLI tests:"
    run_tests "$filter" CLI_TESTS

    echo ""
    echo "Init tests:"
    run_tests "$filter" INIT_TESTS

    echo ""
    echo "Ticket tests:"
    run_tests "$filter" TICKET_TESTS

    echo ""
    echo "Tmux tests:"
    run_tests "$filter" TMUX_TESTS

    echo ""
    echo "Observability tests:"
    run_tests "$filter" OBSERVABILITY_TESTS

    echo ""
    echo "Distributed tickets tests:"
    run_tests "$filter" DISTRIBUTED_TESTS

    # Print summary
    print_summary
}

main "$@"
