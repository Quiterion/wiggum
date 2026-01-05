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

**wiggum tools follow this pattern.**

```
wiggum fetch <pane> <prompt> → summarized insight
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

### wiggum fetch

Summarize a worker's progress.

```bash
wiggum fetch <pane-id> [prompt]
```

**Arguments:**
- `pane-id` — The pane to analyze
- `prompt` — Natural language guidance for summarization (optional)

**Examples:**

```bash
# General progress summary
wiggum fetch worker-0
# → "Implemented auth middleware in src/middleware/auth.ts.
#    Added 3 test cases, all passing. Ready for review."

# Focused query
wiggum fetch worker-0 "any blockers or concerns?"
# → "No blockers. Minor concern: rate limiting not yet addressed,
#    noted in ticket for review phase."

# Specific check
wiggum fetch worker-0 "is the test coverage adequate?"
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

### wiggum ticket comment

Append comment to a ticket and notify the worker. See [cli.md](./cli.md#comment) for command details.

This command is listed here because it has **tool-like side effects** beyond simple file editing:

1. Appends timestamped comment to ticket's `## Comment` section
2. If ticket has an assigned pane, pings the worker:
   ```bash
   tmux send-keys -t worker-0 "# Comment added to your ticket. Please address." Enter
   ```

This notification loop is how rejected reviews/QA get the worker's attention.

---

### wiggum digest

Summarize multiple workers or the whole hive.

```bash
wiggum digest [prompt]
```

**Examples:**

```bash
# Overall status
wiggum digest
# → "3 workers active:
#    - worker-0 (tk-5c46): Auth middleware, nearly done
#    - worker-1 (tk-8a2b): Rate limiting, blocked on auth
#    - reviewer-0 (tk-3a1b): Reviewing DB schema, minor issues found
#
#    2 tickets ready for work. No critical blockers."

# Specific question
wiggum digest "what's blocking progress?"
# → "Main blocker: tk-8a2b waiting on tk-5c46 (auth).
#    worker-0 is close to done, should unblock within the hour."
```

---

## Writing Custom Tools

Tools are shell scripts in `.wiggum/tools/` (or system-wide in the wiggum installation).

A tool receives arguments and should output text to stdout.

```bash
#!/bin/bash
# .wiggum/tools/my-custom-tool

TARGET="$1"
PROMPT="$2"

# Gather data
DATA=$(some-command "$TARGET")

# Invoke ephemeral agent for synthesis
echo "$DATA" | wiggum --ephemeral --prompt "$PROMPT"
```

The `wiggum --ephemeral` flag runs a one-shot agent invocation that doesn't create a pane.

---

## Why Natural Language Prompts?

Tools accept prompts because:

1. **Context matters** — "is this ready for review?" vs "any security concerns?" need different analysis
2. **Supervisor knows best** — The supervisor has context about what matters right now
3. **Flexible** — Same tool serves many purposes without proliferating commands

This mirrors how a human manager asks questions: "give me a status update" vs "are there any blockers I should know about?" — same report, different lens.
