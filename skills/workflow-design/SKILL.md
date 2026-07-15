---
name: workflow-design
description: >
  Reference pack and templates for the workflow-architect agent. Encodes
  Anthropic's agent-design doctrine, the mandatory two-phase (plan-gated /
  autonomous-execute) lifecycle, mechanical enforcement recipes, and fill-in
  templates for generating Claude Code workflows.
user-invocable: false
disable-model-invocation: true
---

# Workflow Design reference pack

This skill is preloaded into the `workflow-architect` agent. It is not meant to be
invoked directly by users or auto-invoked by Claude — it is context the architect
carries while designing workflows.

## Doctrine (read first)

- **Simplicity ladder**: single prompt → single agent → workflow → autonomous
  multi-agent. Climb only as far as the task forces you.
- **Economics**: single agent ≈ 4× chat tokens; multi-agent ≈ 15×. Justify the
  multiple before fanning out.
- **Delegation contract**: every subagent gets an objective, an output format, a
  tool/source guide, and an effort budget.
- **Enforcement is mechanical**: deny rules + a PreToolUse guard hook, always.
- **Two-phase lifecycle is mandatory** for every generated workflow.

## Files in this pack

| File | Purpose |
| --- | --- |
| `references/patterns.md` | Pattern-selection guide from "Building Effective Agents." |
| `references/two-phase-lifecycle.md` | Exact plan→execute handoff mechanics, verified against current Claude Code docs. |
| `references/enforcement.md` | Deny-rule + guard-hook recipes and how they survive `bypassPermissions`. |
| `templates/orchestrator-agent.md.tmpl` | Phase-2 orchestrator subagent. |
| `templates/worker-agent.md.tmpl` | Tiered worker subagent (with frontmatter guard hook). |
| `templates/plan-command.md.tmpl` | `/<wf>` Phase-1 plan command. |
| `templates/execute-command.md.tmpl` | `/<wf>-execute` Phase-2 command. |
| `templates/settings-snippet.json.tmpl` | Deny rules + hook registration for `.claude/settings.local.json`. |
| `templates/workflow-guard.sh.tmpl` | The guard hook, on every OS. |
| `templates/workflow-guard.ps1.tmpl` | Fallback guard for native Windows with no Git Bash; never the committed default. |
| `templates/README.md.tmpl` | Generated-workflow README. |

## Template substitution tokens

When filling templates, replace these placeholders:

- `{{WF}}` — the workflow's short name (lowercase, hyphenated), e.g. `triage`.
- `{{WF_TITLE}}` — human-readable title, e.g. `Issue Triage`.
- `{{PARAMS}}` — the command's argument hint, e.g. `<issue-url>`.
- `{{AGENT_ROSTER}}` — bulleted list of generated agents with model tiers.
- `{{WORKER_NAME}}`, `{{WORKER_MODEL}}`, `{{WORKER_EFFORT}}`,
  `{{WORKER_MAXTURNS}}`, `{{WORKER_TOOLS}}`, `{{WORKER_OBJECTIVE}}` — per worker.

There is deliberately no token for the guard filename or the hook shell. Generated
artifacts get committed and cloned onto other OSes, so they must not encode the
generating host: every workflow registers `workflow-guard.sh` under
`"shell": "bash"`, whatever machine designed it. See `references/enforcement.md`.
