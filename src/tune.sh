#!/usr/bin/env bash
#
# tune.sh - Add "signs" to PROMPT.md when Ralph misbehaves
#
# Usage:
#   ./tune.sh "Don't use placeholder implementations"
#   ./tune.sh "Always run tests after changes"
#   ./tune.sh --list                    # Show current signs
#   ./tune.sh --remove 3                # Remove sign #3
#   ./tune.sh --clear                   # Remove all signs
#

set -euo pipefail

PROMPT_FILE="${PROMPT_FILE:-PROMPT.md}"
SIGNS_MARKER="## Signs"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# Ensure prompt file exists
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo -e "${RED}Error: $PROMPT_FILE not found${NC}" >&2
    exit 1
fi

# Add signs section if it doesn't exist
ensure_signs_section() {
    if ! grep -q "^$SIGNS_MARKER" "$PROMPT_FILE"; then
        echo "" >> "$PROMPT_FILE"
        echo "$SIGNS_MARKER" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
        echo "(Signs are added when Ralph misbehaves. They guide future iterations.)" >> "$PROMPT_FILE"
        echo "" >> "$PROMPT_FILE"
    fi
}

# List current signs
list_signs() {
    if ! grep -q "^$SIGNS_MARKER" "$PROMPT_FILE"; then
        echo "No signs section found"
        return
    fi

    echo -e "${YELLOW}Current signs in $PROMPT_FILE:${NC}"
    echo ""

    # Extract lines after Signs marker that start with a number
    awk '/^## Signs/,/^## [^S]|^$/ { if (/^[0-9]+\./) print }' "$PROMPT_FILE" | \
        while read -r line; do
            echo "  $line"
        done

    local count=$(awk '/^## Signs/,/^## [^S]|^$/ { if (/^[0-9]+\./) count++ } END { print count+0 }' "$PROMPT_FILE")
    echo ""
    echo "Total: $count sign(s)"
}

# Add a new sign
add_sign() {
    local sign="$1"
    ensure_signs_section

    # Count existing signs
    local count=$(awk '/^## Signs/,/^## [^S]|^$/ { if (/^[0-9]+\./) count++ } END { print count+0 }' "$PROMPT_FILE")
    local new_num=$((count + 1))

    # Insert the new sign after the Signs section header
    # Find the line number of the Signs section
    local signs_line=$(grep -n "^$SIGNS_MARKER" "$PROMPT_FILE" | cut -d: -f1)

    # Create temp file with new sign inserted
    {
        head -n "$signs_line" "$PROMPT_FILE"
        echo ""
        echo "${new_num}. ${sign}"
        tail -n +"$((signs_line + 1))" "$PROMPT_FILE"
    } > "${PROMPT_FILE}.tmp"

    mv "${PROMPT_FILE}.tmp" "$PROMPT_FILE"

    echo -e "${GREEN}Added sign #${new_num}:${NC} $sign"
}

# Remove a sign by number
remove_sign() {
    local num="$1"

    if ! grep -q "^${num}\." "$PROMPT_FILE"; then
        echo -e "${RED}Sign #${num} not found${NC}" >&2
        exit 1
    fi

    sed -i "/^${num}\./d" "$PROMPT_FILE"
    echo -e "${YELLOW}Removed sign #${num}${NC}"

    # Renumber remaining signs
    # This is a bit tricky, so we'll leave gaps for simplicity
    echo "(Note: Sign numbers may have gaps now. Use --list to see current signs)"
}

# Clear all signs
clear_signs() {
    if ! grep -q "^$SIGNS_MARKER" "$PROMPT_FILE"; then
        echo "No signs section found"
        return
    fi

    # Remove the entire signs section
    sed -i '/^## Signs/,/^## [^S]/{ /^## [^S]/!d }' "$PROMPT_FILE"
    # Also remove the Signs header if it's at the end
    sed -i '/^## Signs/d' "$PROMPT_FILE"

    echo -e "${YELLOW}Cleared all signs${NC}"
}

# Main
case "${1:-}" in
    --list|-l)
        list_signs
        ;;
    --remove|-r)
        if [[ -z "${2:-}" ]]; then
            echo "Usage: $0 --remove <number>" >&2
            exit 1
        fi
        remove_sign "$2"
        ;;
    --clear|-c)
        read -p "Clear all signs? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            clear_signs
        fi
        ;;
    --help|-h|"")
        echo "Usage: $0 <sign message>"
        echo "       $0 --list           Show current signs"
        echo "       $0 --remove <num>   Remove sign by number"
        echo "       $0 --clear          Remove all signs"
        echo ""
        echo "Examples:"
        echo "  $0 \"Don't use placeholder implementations\""
        echo "  $0 \"Always run tests after making changes\""
        echo "  $0 \"Search before assuming code doesn't exist\""
        ;;
    *)
        add_sign "$1"
        ;;
esac
