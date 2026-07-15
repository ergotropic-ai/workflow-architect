# The mandatory two-phase lifecycle

Every generated workflow separates planning from execution with exactly one human
approval gate. This is verified against current Claude Code behavior (July 2026).

## Why two phases

- Plan mode is read-only: Claude explores and proposes but cannot edit source.
  This lets a human catch a wrong approach before any change is made.
- `bypassPermissions` (`--dangerously-skip-permissions`) lets execution run
  uninterrupted, but it is dangerous. It must be *earned* by an approved plan and
  *constrained* by deny rules and a guard hook.
- **Key constraint**: you cannot switch into `bypassPermissions` mid-session. A
  session must be *started* with the flag. Therefore the handoff between phases is
  a **relaunch**, and the plan is persisted to disk so the fresh session can pick
  it up.

## Phase 1 — Plan (gated, read-only)

Command: `/<wf> "<params>"`. Because slash-command frontmatter has **no
`permission-mode` field**, Phase 1 is gated two ways that reinforce each other:

1. The command's first instruction is a mandatory `EnterPlanMode` step.
2. The README tells the user to launch with `claude --permission-mode plan` (or
   `Shift+Tab` to plan mode) as a belt-and-braces measure.

In Phase 1 the orchestrator does read-only discovery (delegating to a
`{{WF}}-planner` subagent whose frontmatter sets `permissionMode: plan`), then
presents a plan containing these literal sections:

```
## Steps              (ordered; subagent + model tier per step)
## Agents             (roster; effort budget per agent)
## Files touched      (every file/dir to be created or modified)
## Commands           (every shell command class to be executed)
## Network & installs (explicit allowlist; empty means none permitted)
## Scope estimate     (size of change + token-cost class)
```

**Approval of this plan is the single human gate for the run.** On approval, the
command writes:

- `.workflow/plan.md` — the plan verbatim, with a header line `status: approved`.
- `.workflow/allowlist.txt` — one permitted network/install command pattern per
  line (empty if none were approved).

Then it **stops** and prints the Phase 2 relaunch instructions.

## Phase 2 — Execute (autonomous)

Command: `/<wf>-execute`. Runs only in a session started with bypass permissions.

**Preflight (refuse to proceed unless all hold):**
1. `.workflow/plan.md` exists with `status: approved`.
2. The guard hook file exists AND `.claude/settings.local.json` registers the
   `workflow-guard` PreToolUse hook and the deny rules. If missing, install from
   the README snippet and tell the user to restart.
3. The session was started with bypass permissions (if permission prompts appear,
   tell the user to relaunch per the README).

**Self-constraining execution rules (permissions are off):**
- All writes stay inside the project directory and `.workflow/`. Never `$HOME`,
  system paths, or other repositories.
- No destructive git: no force push, `reset --hard`, branch deletion; no
  `rm -rf` outside `.workflow/`.
- Network calls and package installs only if matched by
  `.workflow/allowlist.txt`.
- Anything outside `.workflow/plan.md` scope: STOP, write the reason to
  `.workflow/replan-needed.md`, and tell the user to re-run `/<wf>`. Never
  improvise.
- After each step: append to `.workflow/log.md` and checkpoint
  `.workflow/state.md` (so compaction/restart is safe).
- Finish with the plan's verification step plus a fresh-context subagent review
  of the diff against `.workflow/plan.md`.

## The exact invocation the README documents

```bash
# Phase 1 — normal session; the command forces plan mode itself
claude
> /<wf> "params"
# Review the plan. Approving it is the single human gate.
# Claude writes .workflow/plan.md and stops.

# Phase 2 — bypassPermissions cannot be entered mid-session, so relaunch:
claude --dangerously-skip-permissions        # fresh session, clean context (recommended)
> /<wf>-execute

# Alternative (higher token cost, keeps planning context):
claude --continue --dangerously-skip-permissions
> /<wf>-execute
```

## Mandatory safety warning (goes in every README)

`--dangerously-skip-permissions` disables permission prompts and most safety
checks and offers no protection against prompt injection. Per Anthropic's
guidance, run Phase 2 only in an isolated environment — a container, VM, dev
container, or a dedicated sandbox directory. Claude Code refuses this flag when
running as root/sudo. Note that deny rules and the guard hook remain active even
in this mode, and explicit `ask` rules and root/home deletions still prompt.

## `.workflow/` scratch directory layout

```
.workflow/
├── plan.md            # approved plan (status: approved)
├── allowlist.txt      # permitted network/install command patterns
├── state.md           # orchestrator checkpoint after each phase
├── log.md             # append-only execution log
├── replan-needed.md   # written iff execution hit out-of-scope work
└── steps/
    ├── 01-<name>.md   # full worker output (workers return only summaries)
    └── ...
```
