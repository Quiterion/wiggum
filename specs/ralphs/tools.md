# Tools

Tools are commands that help the supervisor (and hooks) stay context-light by returning **insights** instead of raw data.

---

## The WebFetch Analogy

Consider Claude Code's `WebFetch` tool:

```
WebFetch(url, prompt) → summarized insight
```

You give it a URL and a natural language prompt. Internally, it:
1. Fetches the page content
2. Invokes an LLM to process it according to your prompt
3. Returns a concise summary

You don't see the raw HTML. You don't see the internal LLM call. You get **insight**.

**ralphs tools follow this pattern.**

```
ralphs fetch <pane> <prompt> → summarized insight
```

Internally, the tool:
1. Captures pane output / reads artifacts
2. Invokes an ephemeral agent to analyze according to your prompt
3. Returns a concise summary

The supervisor's context stays clean. The "grunt work" of reading trajectories and synthesizing insights is handled by **black-box ephemeral agents** that don't need their own panes.

---

## Observable vs Ephemeral

| Observable (panes) | Ephemeral (tool internals) |
|--------------------|---------------------------|
| Long-running work | Quick summarization |
| Human oversight needed | Fire-and-forget |
| Produces artifacts | Returns insight |
| Workers, reviewers, QA | Tool implementations |

The distinction: if work is substantial enough to warrant observation and potential intervention, it gets a pane. If it's a quick internal operation, it stays ephemeral.

---

## Tool Reference

### ralphs fetch

Summarize a worker's progress.

```bash
ralphs fetch <pane-id> [prompt]
```

**Arguments:**
- `pane-id` — The pane to analyze
- `prompt` — Natural language guidance for summarization (optional)

**Examples:**

```bash
# General progress summary
ralphs fetch impl-0
# → "Implemented auth middleware in src/middleware/auth.ts.
#    Added 3 test cases, all passing. Ready for review."

# Focused query
ralphs fetch impl-0 "any blockers or concerns?"
# → "No blockers. Minor concern: rate limiting not yet addressed,
#    noted in ticket for review phase."

# Specific check
ralphs fetch impl-0 "is the test coverage adequate?"
# → "Coverage looks thin. Only happy path tested. Missing:
#    expired token, malformed token, missing token cases."
```

**Implementation:**
1. `tmux capture-pane` to get recent output
2. Read git diff for changes by this worker
3. Read the assigned ticket for context
4. Invoke ephemeral agent with: output + diff + ticket + prompt
5. Return summary (~100-200 tokens)

---

### ralphs context

Build a briefing for an agent about to start work.

```bash
ralphs context <ticket-id> [prompt]
```

**Arguments:**
- `ticket-id` — The ticket to build context for
- `prompt` — What aspect to focus on (optional)

**Examples:**

```bash
# Full briefing
ralphs context tk-5c46
# → "Ticket: Implement auth middleware
#    Dependencies: tk-3a1b (done) - database schema
#    Related specs: specs/api.md, specs/auth.md
#    Recent activity: Created 2h ago, no work started yet"

# Focused briefing
ralphs context tk-5c46 "what specs are relevant?"
# → "Relevant specs:
#    - specs/auth.md: JWT format, token expiry rules
#    - specs/api.md: Middleware chain, error response format"
```

**Implementation:**
1. Read ticket file
2. Resolve dependencies, read their summaries
3. Scan specs/ for related documents (by keyword, references)
4. Invoke ephemeral agent to synthesize briefing
5. Return summary

---

### ralphs inject-feedback

Append feedback to a ticket and notify the worker.

```bash
ralphs inject-feedback <ticket-id> <source> <message>
```

**Arguments:**
- `ticket-id` — Target ticket
- `source` — Who's giving feedback (e.g., "reviewer", "qa")
- `message` — The feedback content

**Example:**

```bash
ralphs inject-feedback tk-5c46 reviewer "Missing rate limiting. Add test for expired tokens."
```

**Effect:**
1. Appends to ticket's Feedback section:
   ```markdown
   ### From reviewer (2025-07-14 14:30)

   Missing rate limiting. Add test for expired tokens.
   ```
2. If ticket has an assigned pane, pings it:
   ```bash
   tmux send-keys -t impl-0 "# Feedback added to your ticket. Please address." Enter
   ```

---

### ralphs digest

Summarize multiple workers or the whole hive.

```bash
ralphs digest [prompt]
```

**Examples:**

```bash
# Overall status
ralphs digest
# → "3 workers active:
#    - impl-0 (tk-5c46): Auth middleware, nearly done
#    - impl-1 (tk-8a2b): Rate limiting, blocked on auth
#    - review-0 (tk-3a1b): Reviewing DB schema, minor issues found
#
#    2 tickets ready to claim. No critical blockers."

# Specific question
ralphs digest "what's blocking progress?"
# → "Main blocker: tk-8a2b waiting on tk-5c46 (auth).
#    impl-0 is close to done, should unblock within the hour."
```

---

## Writing Custom Tools

Tools are shell scripts in `.ralphs/tools/` (or system-wide in the ralphs installation).

A tool receives arguments and should output text to stdout.

```bash
#!/bin/bash
# .ralphs/tools/my-custom-tool

TARGET="$1"
PROMPT="$2"

# Gather data
DATA=$(some-command "$TARGET")

# Invoke ephemeral agent for synthesis
echo "$DATA" | ralphs --ephemeral --prompt "$PROMPT"
```

The `ralphs --ephemeral` flag runs a one-shot agent invocation that doesn't create a pane.

---

## Why Natural Language Prompts?

Tools accept prompts because:

1. **Context matters** — "is this ready for review?" vs "any security concerns?" need different analysis
2. **Supervisor knows best** — The supervisor has context about what matters right now
3. **Flexible** — Same tool serves many purposes without proliferating commands

This mirrors how a human manager asks questions: "give me a status update" vs "are there any blockers I should know about?" — same report, different lens.
