<h1 align="center">claude-code-todo-fix</h1>

<p align="center">
  <strong>Get the todo / task list back in Claude Code.</strong><br>
  For Opus 5, Opus 4.8, Sonnet 5, Fable 5.1, Fable 5, Mythos 5.1, Mythos 5 and newer models,<br>
  where Claude Code 2.1.233 turned it off.
</p>

<p align="center">
  <a href="https://github.com/jx-grxf/claude-code-todo-fix/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/jx-grxf/claude-code-todo-fix/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"><img alt="Claude Code 2.1.233+" src="https://img.shields.io/badge/Claude_Code-2.1.233%2B-D97757?logo=claude&amp;logoColor=white"></a>
  <a href="#quickstart"><img alt="Setup: 1 minute" src="https://img.shields.io/badge/setup-1_minute-2ea44f"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

## The problem

Claude Code used to show a checklist that it ticked off step by step. After an
update it's gone: no todo list, no `TodoWrite`, no `TaskCreate`, and
<kbd>Ctrl</kbd>+<kbd>T</kbd> shows nothing.

That's intentional. From the
[Claude Code 2.1.233 changelog](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md):

> Todo/task-tracking tools (TaskCreate/Get/Update/List, TodoWrite) are no longer
> available on Opus 4.8, Sonnet 5, Fable 5, Mythos 5, and newer models; set
> `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` to bring them back

Setting that variable is only half the fix. The tools come back as *deferred*
tools: Claude sees their names but not their instructions until it loads them
through tool search, so it usually doesn't use them. This repo covers both
halves:

| Step | File | What it does |
|---|---|---|
| 1 | `~/.claude/settings.json` | `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` enables the task tools again |
| 2 | `~/.claude/CLAUDE.md` | A short rule tells Claude to load the task tools and keep the list current on multi-step work |

## Affected models

Claude Code decides this per model family and version: Opus 4.8 or newer, and
Sonnet, Fable or Mythos 5 or newer. Checked against Claude Code 2.1.267:

| Model | Model ID | Task list without this fix |
|---|---|---|
| Claude Opus 5 | `claude-opus-5` | ❌ off |
| Claude Opus 4.8 | `claude-opus-4-8` | ❌ off |
| Claude Sonnet 5 | `claude-sonnet-5` | ❌ off |
| Claude Fable 5.1 | `claude-fable-5-1` | ❌ off |
| Claude Fable 5 | `claude-fable-5` | ❌ off |
| Claude Mythos 5.1 | `claude-mythos-5-1` | ❌ off |
| Claude Mythos 5 | `claude-mythos-5` | ❌ off |
| Any newer Opus, Sonnet, Fable or Mythos model | | ❌ off |
| Claude Opus 4.7 and older (4.6, 4.5, 4.1, 4) | | ✅ on |
| Claude Sonnet 4.6 and older (4.5, 4, 3.7) | | ✅ on |
| All Claude Haiku models (4.5, 4, 3.5) | | ✅ on |

## Quickstart

No clone or download needed: the prompt below contains everything. Paste it
into Claude Code, then restart Claude Code:

```text
Restore my Claude Code task list:

1. Back up ~/.claude/settings.json if it exists. Then set
   "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1" inside its "env" object, creating the
   file or the object if needed. Keep every other setting unchanged.
2. Add the block below to the end of ~/.claude/CLAUDE.md, creating the file if
   needed. If a block with the same start and end markers already exists,
   replace it instead of adding a second one.
3. Show me what changed in both files and remind me to restart Claude Code.

<!-- claude-code-todo-fix:start -->
## Task list
- For work with 3+ steps, first load the task tools with
  `ToolSearch("select:TaskCreate,TaskUpdate,TaskList")`, create one task per
  step, and keep statuses current (`in_progress` when starting, `completed`
  when done). The user follows progress through this list.
<!-- claude-code-todo-fix:end -->
```

If you set `CLAUDE_CONFIG_DIR`, use that directory instead of `~/.claude`.

## Other ways to install

### Script

If you'd rather run a script than ask an agent:

```bash
git clone https://github.com/jx-grxf/claude-code-todo-fix.git
cd claude-code-todo-fix
./install.sh
```

Requires `python3`. Safe to run again: it only writes when something changes,
backs up every file it touches (`*.bak-<timestamp>`), keeps symlinked dotfiles
intact, refuses to edit an invalid `settings.json`, and respects
`CLAUDE_CONFIG_DIR`.

### By hand

1. Add the flag to `~/.claude/settings.json`:

   ```json
   {
     "env": {
       "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"
     }
   }
   ```

2. Append [`snippet/CLAUDE.md`](snippet/CLAUDE.md) to `~/.claude/CLAUDE.md`.
3. Restart Claude Code.

## Check that it works

1. Inside Claude Code, run `! echo $CLAUDE_CODE_ENABLE_TODO_TOOLS`. It should print `1`.
2. Give Claude a job with a few steps, for example *"Add a `--verbose` flag,
   document it in the README and write a test for it."*
3. A task list shows up and updates as Claude works.
   <kbd>Ctrl</kbd>+<kbd>T</kbd> shows or hides it.

## Trade-offs

Nothing breaks, but the list isn't free:

- **Context.** Loading the task tools adds about 2k tokens to the session, and
  every task update is an extra short tool call.
- **Reminders.** With the flag on, Claude Code now and then adds a "task tools
  haven't been used recently" reminder to the context, even in sessions that
  don't need a list.
- **Stability.** The flag is announced in the changelog but not listed in the
  environment variable docs, so a future release could rename or drop it. If
  the list disappears again after an update, check the changelog.

On the plus side, tasks are stored on disk under `~/.claude/tasks/`, so the
list survives context compaction and resumed sessions.

## Why not just…

**…set `ENABLE_TOOL_SEARCH=false`?** That stops deferring tools altogether. The
task tools load, but so does every tool from every connected MCP server, on
every request. With a few MCP servers that costs far more context than this fix.

**…go back to `TodoWrite` with `CLAUDE_CODE_ENABLE_TASKS=false`?** You can if
you prefer the older single-checklist tool. On newer models it still needs
`CLAUDE_CODE_ENABLE_TODO_TOOLS=1` and it's deferred too, so change the rule to
`ToolSearch("select:TodoWrite")`.

**…use `alwaysLoad`?** That option only exists for MCP servers. Built-in tools
like `TaskCreate` can't be pinned from your settings.

## FAQ

### Why is my Claude Code todo list not showing anymore?

Since Claude Code 2.1.233, the todo and task tools (`TodoWrite`, `TaskCreate`,
`TaskUpdate`, `TaskList`, `TaskGet`) are turned off on Claude Opus 5, Opus 4.8,
Sonnet 5, Fable 5.1, Fable 5, Mythos 5.1, Mythos 5 and newer models. Follow the
[Quickstart](#quickstart) to get them back.

### I set `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` but still don't see a task list

The tools are available again but deferred, so Claude rarely loads them on its
own. Add the `CLAUDE.md` rule from step 2 and restart Claude Code.

### Does this change anything on older models?

No. Haiku models, Opus 4.7 and older, and Sonnet 4.6 and older never lost the
tools. The flag has no effect there and the rule is harmless.

## Uninstall

```bash
./uninstall.sh
```

Or remove `CLAUDE_CODE_ENABLE_TODO_TOOLS` from `settings.json` and delete the
block between the `claude-code-todo-fix` markers in `CLAUDE.md`. Then restart
Claude Code.

---

Unofficial community fix, not affiliated with Anthropic. [MIT License](LICENSE).
