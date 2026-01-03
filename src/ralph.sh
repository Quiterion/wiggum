#!/usr/bin/env bash
#
# ralph.sh - Run an AI coding agent in an autonomous loop
#
# Usage:
#   ./ralph.sh                    # Run continuous loop with default agent (claude)
#   AGENT=amp ./ralph.sh          # Use a different agent
#   ONCE=1 ./ralph.sh             # Run single iteration
#   DRY_RUN=1 ./ralph.sh          # Echo prompt instead of running agent
#
# Environment:
#   AGENT     - Agent command to use (default: claude)
#   AGENT_ARGS - Additional args for agent (default: --print)
#   ONCE      - If set, run only one iteration
#   DRY_RUN   - If set, echo prompt instead of running agent
#   SLEEP     - Seconds between iterations (default: 2)
#

set -euo pipefail

# Configuration
AGENT="${AGENT:-claude}"
AGENT_ARGS="${AGENT_ARGS:---print}"
PROMPT_FILE="${PROMPT_FILE:-PROMPT.md}"
SLEEP="${SLEEP:-2}"
LOG_DIR="${LOG_DIR:-.ralph}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Ensure we're in a git repo with required files
check_requirements() {
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo -e "${RED}Error: $PROMPT_FILE not found${NC}" >&2
        echo "Run 'ralph init' to set up a new project" >&2
        exit 1
    fi

    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        echo -e "${RED}Error: Not in a git repository${NC}" >&2
        exit 1
    fi
}

# Log with timestamp
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $*"
}

# Run single iteration
run_iteration() {
    local iteration=$1
    local start_time=$(date +%s)

    log "${GREEN}=== Iteration $iteration ===${NC}"

    if [[ -n "${DRY_RUN:-}" ]]; then
        log "${YELLOW}[DRY RUN] Would pipe to: $AGENT $AGENT_ARGS${NC}"
        echo "---"
        cat "$PROMPT_FILE"
        echo "---"
        return 0
    fi

    # Pipe prompt to agent
    log "Running: cat $PROMPT_FILE | $AGENT $AGENT_ARGS"

    if cat "$PROMPT_FILE" | $AGENT $AGENT_ARGS; then
        log "${GREEN}Agent completed successfully${NC}"
    else
        log "${RED}Agent exited with error${NC}"
    fi

    # Auto-commit if there are changes
    if ! git diff --quiet HEAD 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
        log "Committing changes..."
        git add -A
        git commit -m "ralph: iteration $iteration ($(date '+%Y-%m-%d %H:%M:%S'))" || true
    else
        log "No changes to commit"
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log "Iteration $iteration completed in ${duration}s"
}

# Graceful shutdown
cleanup() {
    echo ""
    log "${YELLOW}Shutting down Ralph...${NC}"
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main
main() {
    check_requirements

    mkdir -p "$LOG_DIR"

    log "${GREEN}Starting Ralph${NC}"
    log "Agent: $AGENT $AGENT_ARGS"
    log "Prompt: $PROMPT_FILE"

    local iteration=1

    while true; do
        run_iteration $iteration

        if [[ -n "${ONCE:-}" ]]; then
            log "Single iteration mode - exiting"
            break
        fi

        log "Sleeping ${SLEEP}s before next iteration..."
        sleep "$SLEEP"

        ((iteration++))
    done
}

main "$@"
