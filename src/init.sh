#!/usr/bin/env bash
#
# init.sh - Initialize a new Ralph project
#
# Usage:
#   ./init.sh              # Initialize in current directory
#   ./init.sh myproject    # Create and initialize myproject/
#

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PROJECT_DIR="${1:-.}"

# Create project directory if specified
if [[ "$PROJECT_DIR" != "." ]]; then
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    echo -e "${GREEN}Created $PROJECT_DIR${NC}"
fi

# Initialize git if needed
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    git init
    echo -e "${GREEN}Initialized git repository${NC}"
fi

# Create directories
mkdir -p specs src

# Create PROMPT.md template
if [[ ! -f PROMPT.md ]]; then
    cat > PROMPT.md << 'EOF'
# Task

Your task is to implement the project according to the specifications.

## Context

Study `@specs/` to understand what needs to be built.
Check `@fix_plan.md` for current status and priorities.

## Process

1. Study the specs and fix_plan.md
2. Choose the single most important thing to implement
3. Implement it fully (no placeholders!)
4. Update fix_plan.md with progress
5. Commit your changes

## Constraints

- One task per loop - focus on the most important thing
- Before implementing, search codebase (don't assume not implemented)
- Run tests after implementing
- Keep AGENT.md updated with build/test learnings
EOF
    echo -e "${GREEN}Created PROMPT.md${NC}"
fi

# Create fix_plan.md template
if [[ ! -f fix_plan.md ]]; then
    cat > fix_plan.md << 'EOF'
# Fix Plan

## Priority 1: Core
- [ ] First thing to build
- [ ] Second thing to build

## Priority 2: Features
- [ ] Feature A
- [ ] Feature B

## Priority 3: Polish
- [ ] Documentation
- [ ] Tests

## Completed
(nothing yet)
EOF
    echo -e "${GREEN}Created fix_plan.md${NC}"
fi

# Create AGENT.md template
if [[ ! -f AGENT.md ]]; then
    cat > AGENT.md << 'EOF'
# Agent Instructions

## Project Overview
(Describe what this project does)

## Directory Structure
```
.
├── PROMPT.md       # Main prompt fed each loop
├── fix_plan.md     # Living TODO list
├── AGENT.md        # This file
├── specs/          # Specifications
└── src/            # Source code
```

## How to Build
```bash
# Build commands here
```

## How to Test
```bash
# Test commands here
```

## Learnings
(Ralph will update this with things he learns)
EOF
    echo -e "${GREEN}Created AGENT.md${NC}"
fi

# Create specs README
if [[ ! -f specs/README.md ]]; then
    cat > specs/README.md << 'EOF'
# Specifications

This directory contains specifications for the project.

Create one markdown file per component/feature, describing:
- What it should do
- API/interface design
- Constraints and requirements
- Examples

The agent will read these specs and implement accordingly.
EOF
    echo -e "${GREEN}Created specs/README.md${NC}"
fi

# Create .gitignore
if [[ ! -f .gitignore ]]; then
    cat > .gitignore << 'EOF'
.ralph/
*.log
.DS_Store
EOF
    echo -e "${GREEN}Created .gitignore${NC}"
fi

echo ""
echo -e "${GREEN}Ralph project initialized!${NC}"
echo ""
echo "Next steps:"
echo "  1. Edit specs/ with your project specifications"
echo "  2. Edit fix_plan.md with your TODO list"
echo "  3. Run: ${YELLOW}ralph${NC} to start the loop"
