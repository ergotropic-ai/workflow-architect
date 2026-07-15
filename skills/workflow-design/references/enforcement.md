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

Add PowerShell equivalents where the PowerShell tool is enabled
(`PowerShell(Remove-Item -Recurse -Force*)` etc.).

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

Templates: `templates/workflow-guard.ps1.tmpl` (primary on Windows) and
`templates/workflow-guard.sh.tmpl` (bash). Register the matching one via the
settings snippet with the correct `"shell"` value.

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
