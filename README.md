# workflow-architect

A Claude Code agent that designs other Claude Code workflows.

Given a task, it produces a complete, reusable workflow — subagents, slash commands,
deny rules, and a guard hook — following Anthropic's published agent-design guidance
and a mandatory two-phase (plan-gated, then autonomous-execute) lifecycle. It designs
and generates workflows; it does not execute them.

## Install

macOS / Linux (or Git Bash on Windows):

```bash
git clone https://github.com/ergotropic-ai/workflow-architect.git
cd workflow-architect
./install.sh           # add --dry-run to preview
```

Windows PowerShell:

```powershell
git clone https://github.com/ergotropic-ai/workflow-architect.git
cd workflow-architect
.\install.ps1          # add -WhatIf to preview
```

The installer copies three things into `~/.claude`, which is what makes them
available from any directory in any session:

| Repo path | Installs to | What it is |
| --- | --- | --- |
| `agents/workflow-architect.md` | `~/.claude/agents/` | The agent definition |
| `commands/design-workflow.md` | `~/.claude/commands/` | The `/design-workflow` command |
| `skills/workflow-design/` | `~/.claude/skills/` | Reference pack + templates the agent reads |

Existing files are moved to `.bak` before being overwritten. Start a new session
afterward — the agent registry is read at startup.

## Use

```
/design-workflow <task description>
```

The agent asks clarifying questions, proposes a design, and gates on your approval
before generating files into the target project.

## Design doctrine

The agent applies a **simplicity ladder** — single prompt → single agent → workflow →
autonomous multi-agent — and climbs only as far as the task forces it. The economics
justify the caution: a single agent costs roughly 4× a chat turn, multi-agent roughly
15×. Every generated subagent gets an explicit delegation contract (objective, output
format, tool guide, effort budget), and enforcement is always mechanical — deny rules
plus a `PreToolUse` guard hook, never prompt-based pleading.

See `skills/workflow-design/references/` for the full rationale:
`patterns.md` (pattern selection), `two-phase-lifecycle.md` (plan→execute handoff),
and `enforcement.md` (guard-hook recipes, including how they survive
`bypassPermissions`).

## Tests

```powershell
.\tests\run-tests.ps1        # 105 tests: structure, frontmatter, templates, portability, guard behavior
```

```bash
bash tests/run-guard-tests.sh   # 41 tests: guard ALLOW/DENY matrix + rendered-config portability
```

Both suites are self-contained — no Pester, no installs. The static half checks that
every system file exists, that frontmatter parses, that every template token is
documented in `SKILL.md` (and vice versa), and that templates render with no residual
tokens. The portability half pins the rule that a generated workflow never encodes the
OS that generated it: the rendered settings snippet is bash-pinned, names no Windows
interpreter, and is executed as Claude Code would execute it — under `sh`, `dash`, and
`bash`, with the guard's exec bit cleared. The behavioral half runs the rendered guard
hook against an ALLOW/DENY matrix covering path escapes, destructive git operations,
`rm -rf` variants, and package installs. See `tests/README.md` for the guard defects
these caught.

Both suites test the **installed** copy under `~/.claude`, so run the installer
first (set `CLAUDE_HOME` to test a different install root).

## Layout

```
agents/     commands/     skills/workflow-design/     # the installable system
tests/                                                # test suites
docs/original-spec.md                                 # the prompt this was built from
```

## A note on drift

`~/.claude` is what Claude Code actually loads; this repo is the source of record.
Editing the installed copy directly will silently diverge from git. Edit here and
re-run the installer (`install.sh` / `install.ps1`), or copy changes back before
committing.
