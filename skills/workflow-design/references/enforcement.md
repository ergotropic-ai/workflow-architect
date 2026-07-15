# Mechanical enforcement

Prompt instructions are advisory; hooks and deny rules are deterministic. Because
Phase 2 runs with permissions skipped, the workflow must constrain itself
mechanically. Two facts make this possible:

1. **`permissions.deny` rules apply in every mode**, including
   `bypassPermissions`. Allow rules are ignored under bypass (everything is
   already allowed), but deny rules and explicit `ask` rules still fire.
2. **`PreToolUse` hooks always run**, in every mode. A hook that returns a `deny`
   decision blocks the tool call regardless of permission mode.

So enforcement = deny rules (coarse, declarative) + a guard hook (fine, logic
driven). Belt and braces.

## Layer 1 — deny rules

Merged into the project's `.claude/settings.local.json`. See
`templates/settings-snippet.json.tmpl`. Covers the blunt cases:

- `Bash(git push --force*)`, `Bash(git push -f*)`
- `Bash(git reset --hard*)`
- `Bash(git branch -D *)`, `Bash(git branch -d *)`
- `Bash(git clean*)`, `Bash(git stash drop*)`, `Bash(git stash clear*)`
- `Write(~/**)`, `Edit(~/**)` — no writes to home
- `Read(~/.ssh/**)`, `Read(~/.aws/**)` — no reading secrets

Always include the PowerShell equivalents (`PowerShell(Remove-Item -Recurse
-Force*)` etc.), not only when generating on Windows. Which *tool* Claude may
invoke depends on the host that eventually runs the workflow, not on the host that
designed it — a teammate on native Windows gets the PowerShell tool. This is
independent of which shell runs the hook: the guard is always bash, and it always
matches `Bash|PowerShell`.

## Layer 2 — the guard hook

A `PreToolUse` hook on `Bash|PowerShell|Write|Edit|NotebookEdit`. It reads the
hook JSON from stdin and decides. To block, it prints to stdout:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "workflow-guard: <reason>"
  }
}
```

and exits 0. To defer to the normal flow, it simply exits 0 with no JSON (or exits
0 emitting `"permissionDecision": "defer"`). Exit code 2 also blocks (stderr shown
to Claude), but emitting the JSON deny is clearer.

### Guard logic

1. **Write / Edit / NotebookEdit**: resolve `tool_input.file_path` to an absolute
   path. Deny unless it is inside `$CLAUDE_PROJECT_DIR` (which includes
   `.workflow/`). This blocks writes to `$HOME`, system paths, and sibling repos.
2. **Bash / PowerShell**: inspect `tool_input.command`. Deny if it matches:
   - destructive git: `git push --force`/`-f`, `git reset --hard`,
     `git branch -d`/`-D`, `git clean`, `git stash drop`/`clear`;
   - `rm -rf` / `Remove-Item -Recurse -Force` whose target is **not** inside
     `.workflow/`;
   - a redirect / `tee` / `Set-Content` / `Out-File` targeting a path outside the
     project;
   - a network/install command (`curl`, `wget`, `Invoke-WebRequest`,
     `npm install`, `pip install`, `pnpm add`, `cargo add`, `uv add`, `winget`,
     `choco`, `apt`, `brew`) **unless** the command matches a line in
     `.workflow/allowlist.txt`.
3. Otherwise exit 0 (defer). In Phase 1 the normal flow is plan-mode read-only; in
   Phase 2 it is bypass.

### One guard, every OS

Generated artifacts get committed and cloned onto other machines, so the guard
registration must not encode the OS that generated it. A workflow designed on
Windows that registers `workflow-guard.ps1` leaves a Linux teammate with a hook
that cannot execute — and a hook that cannot execute does not block, it is a
non-blocking error that Claude Code proceeds past. That silently removes the
workflow's safety floor while the README still promises it.

So `templates/workflow-guard.sh.tmpl` is the guard on every OS, registered once:

```json
{
  "type": "command",
  "shell": "bash",
  "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/hooks/workflow-guard.sh\""
}
```

Both details are load-bearing:

- **`"shell": "bash"` is explicit.** The field defaults to `bash`, *but to
  `powershell` on a Windows host with no Git Bash* — which would hand this script
  to the wrong interpreter. Pinning it keeps one committed config deterministic
  everywhere.
- **`bash "<path>"`, not the bare path.** Shell form runs the command under
  `sh -c` on macOS/Linux, and `sh` is dash on Debian/Ubuntu, which cannot parse
  the guard. Naming `bash` explicitly also stops the guard depending on its exec
  bit surviving a clone.

`templates/workflow-guard.ps1.tmpl` stays as a fallback for the one host that has
no bash at all: native Windows without Git for Windows. It is a local swap, never
the committed default, and its ALLOW/DENY behavior must stay identical to the
`.sh` guard.

### The one thing that cannot fail closed

The guard fails closed on its own dependencies — no `jq`, no parse, deny. But if
the hook process itself cannot spawn, Claude Code reports a non-blocking error and
**proceeds**; only exit code 2 or a `deny` decision blocks, and a hook that never
ran produces neither. No hook configuration can close that gap. So the Phase 2
preflight fires a canary payload through the guard and refuses to execute unless it
comes back denied. That is where "the guard cannot run here" becomes a stop.

## Layer 3 — hooks travel with the agents

Duplicate the same `PreToolUse` guard in each worker agent's frontmatter `hooks:`
block. Frontmatter hooks run only while that subagent is active and are cleaned up
afterward, so enforcement follows the agents even if a user copies an agent into a
project whose `settings.local.json` lacks the hook. (Note: frontmatter hooks are
ignored for *plugin* subagents — not a concern here since these are user/project
agents.)

## The allowlist discipline

`.workflow/allowlist.txt` is written **only** by the Phase 1 command, and only
from the approved plan's `## Network & installs` section. The guard hook treats it
as the sole source of truth for permitted network/install commands. If the plan
approved nothing, the file is empty and every network/install call is denied. This
is how "no network calls unless in the approved plan" is enforced mechanically
rather than by prompt.
