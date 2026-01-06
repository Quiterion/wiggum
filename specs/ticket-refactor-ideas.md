# Ticket Refactor Ideas

This document tracked planned improvements to the ticket system. Most have now been implemented.

## Architecture (unchanged)

- wiggum control plane uses configuration and registry in <proj-root>/.wiggum
- wiggum data plane (i.e. tickets) uses distributed hierarchy:
  - origin is bare repo in <proj-root>/.wiggum/tickets.git
  - each agent interacts with a clone in <proj-root>/worktrees/<agent-id>/.wiggum/tickets
- why the nested repo structure? to prevent conceptual drift between agents in parallel project worktrees

## Improvements (IMPLEMENTED)

### ✅ Ticket Type Configuration
- [x] Store in control plane: `.wiggum/ticket_types.json`
- [x] Configurable properties:
  - [x] Allowed ticket states
  - [x] Valid ticket state transitions
  - [x] Pre- and post-transition hook filenames
  - [x] Ticket types (feature, bug, task, etc.)
- Implementation: `lib/ticket_types.sh`, `defaults/ticket_types.json`

### ✅ Hook Invocation from ticket_transition()
- [x] Removed git hooks from `.wiggum/tickets.git` (bare repo has no hooks)
- [x] Hooks invoked directly by `ticket_transition()`:
  - [x] Pre-transition hooks run before state change (can block)
  - [x] Post-transition hooks run after push (async, background)
- [x] Pre-transition hooks run in worktree context
- Implementation: `lib/ticket.sh:ticket_transition()`, `lib/hooks.sh`

### ✅ Enforced Data Layer Invariants
- [x] CRUD API in `lib/ticket.sh` is the only code that accesses `$TICKETS_DIR`
- [x] Every CRUD operation:
  - [x] Pulls from origin before reading
  - [x] Pushes to origin after writing
- [x] Sync is mandatory (removed `--no-sync` flag)
- [x] Frontmatter utils (`_get_frontmatter_value`, `_set_frontmatter_value`) are internal
- [x] External code uses CRUD wrappers (`read_ticket_content`, `get_ticket_field`, etc.)
- Implementation: `lib/ticket.sh` CRUD section

## Invariants (ENFORCED)

1. All control-plane config/registry operations use `$MAIN_WIGGUM_DIR`
2. All ticket operations use CRUD wrappers that enforce sync
3. Only CRUD wrappers may reference `$TICKETS_DIR` directly
