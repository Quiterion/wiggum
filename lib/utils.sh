#!/bin/bash
#
# utils.sh - Common utility functions
#

# Colors (only if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

# Logging functions
log() {
    [[ "$RALPHS_QUIET" == "true" ]] && return
    echo -e "$@"
}

info() {
    log "${BLUE}[info]${NC} $*"
}

success() {
    log "${GREEN}[ok]${NC} $*"
}

warn() {
    log "${YELLOW}[warn]${NC} $*" >&2
}

error() {
    echo -e "${RED}[error]${NC} $*" >&2
}

debug() {
    # shellcheck disable=SC2015
    [[ "$RALPHS_VERBOSE" == "true" ]] && log "${CYAN}[debug]${NC} $*" || true
}

# Generate a short random ID (4 hex chars)
generate_id() {
    local prefix="${1:-tk}"
    local id
    id=$(printf '%04x' $RANDOM)
    echo "${prefix}-${id}"
}

# Get current timestamp in ISO format
timestamp() {
    date -Iseconds
}

# Get human-friendly timestamp
human_timestamp() {
    date "+%Y-%m-%d %H:%M"
}

# Calculate duration from ISO timestamp to now
duration_since() {
    local start="$1"
    local start_epoch
    start_epoch=$(date -d "$start" +%s 2>/dev/null || echo 0)
    local now_epoch
    now_epoch=$(date +%s)
    local diff
    diff=$((now_epoch - start_epoch))

    if [[ $diff -lt 60 ]]; then
        echo "${diff}s"
    elif [[ $diff -lt 3600 ]]; then
        echo "$((diff / 60))m"
    else
        local hours
    hours=$((diff / 3600))
        local mins
    mins=$(((diff % 3600) / 60))
        echo "${hours}h ${mins}m"
    fi
}

# Get git repository root
get_git_root() {
    git rev-parse --show-toplevel 2>/dev/null
}

# Get project root (directory containing .ralphs/)
# shellcheck disable=SC2120  # Function accepts optional arg with default
get_project_root() {
    local dir="${1:-$(pwd)}"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.ralphs" ]]; then
            echo "$dir"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

# Ensure we're in a ralphs project
require_project() {
    if ! PROJECT_ROOT=$(get_project_root); then
        error "Not in a ralphs project. Run 'ralphs init' first."
        exit "$EXIT_ERROR"
    fi
    RALPHS_DIR="$PROJECT_ROOT/.ralphs"
    TICKETS_DIR="$RALPHS_DIR/tickets"
    HOOKS_DIR="$RALPHS_DIR/hooks"
    PROMPTS_DIR="$RALPHS_DIR/prompts"
    export PROJECT_ROOT RALPHS_DIR TICKETS_DIR HOOKS_DIR PROMPTS_DIR
}

# Match partial ticket ID
resolve_ticket_id() {
    local partial="$1"
    require_project

    # Exact match first
    if [[ -f "$TICKETS_DIR/${partial}.md" ]]; then
        echo "$partial"
        return 0
    fi

    # Partial match
    local matches=()
    for f in "$TICKETS_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        local name
    name=$(basename "$f" .md)
        if [[ "$name" == *"$partial"* ]]; then
            matches+=("$name")
        fi
    done

    if [[ ${#matches[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#matches[@]} -eq 1 ]]; then
        echo "${matches[0]}"
        return 0
    else
        error "Ambiguous ticket ID '$partial'. Matches: ${matches[*]}"
        return 1
    fi
}

# Parse YAML frontmatter from markdown file
# Usage: get_frontmatter_value <file> <key>
get_frontmatter_value() {
    local file="$1"
    local key="$2"

    awk -v key="$key" '
        /^---$/ { in_fm = !in_fm; next }
        in_fm && $1 == key":" {
            sub(/^[^:]+:[[:space:]]*/, "")
            print
            exit
        }
    ' "$file"
}

# Update a frontmatter value in a markdown file
set_frontmatter_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    local temp
    temp=$(mktemp)
    awk -v key="$key" -v value="$value" '
        /^---$/ { in_fm = !in_fm; print; next }
        in_fm && $1 == key":" {
            print key ": " value
            found = 1
            next
        }
        { print }
    ' "$file" > "$temp"
    mv "$temp" "$file"
}

# Check if a command exists
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        error "Required command not found: $cmd"
        exit "$EXIT_ERROR"
    fi
}

# Simple table formatting
print_table_header() {
    printf "${BOLD}%-10s %-12s %-10s %-12s %-10s${NC}\n" "$@"
}

print_table_row() {
    printf "%-10s %-12s %-10s %-12s %-10s\n" "$@"
}

# Ensure directory exists
ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}
