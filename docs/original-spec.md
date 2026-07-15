# Claude Code Prompt: Workflow Architect Agent (Plan Mode)

I want you to build a reusable "Workflow Architect" agent for Claude Code. Enter plan mode and design this before writing anything.

## What to build

A Claude Code subagent (in `~/.claude/agents/` so it's available globally across all my projects and terminal sessions) called `workflow-architect`, invoked via a companion slash command (e.g. `/design-workflow "<task description>"`), that runs on the claude-fable-5 model.

## Ground the design in Anthropic's published best practices

Before designing, fetch and read Anthropic's own guidance on agent design, and treat it as the authority for the architect's design philosophy:

- "Building Effective Agents" (anthropic.com/engineering/building-effective-agents)
- "How we built our multi-agent research system" (anthropic.com/engineering/multi-agent-research-system)
- "Claude Code: Best practices for agentic coding" (anthropic.com/engineering/claude-code-best-practices)
- The Claude Code docs on subagents, slash commands, hooks, and permission modes (docs.claude.com)

The architect agent's system prompt must encode these principles explicitly:

- Start with the simplest pattern that works: prefer plain prompts > workflows (prompt chaining, routing, parallelization, orchestrator-workers, evaluator-optimizer) > fully autonomous agents. Only recommend multi-agent when the task genuinely needs it.
- Match the pattern to the task: routing for classification-style branching, parallelization for independent subtasks, orchestrator-workers for unpredictable decomposition, evaluator-optimizer when there are clear evaluation criteria and iteration helps.
- Give each subagent a clear objective, output format, and explicit guidance on tools and effort budget — vague delegation causes duplicated work and wasted tokens.
- Design tool interfaces as carefully as prompts (clear names, descriptions, minimal surface area).
- Multi-agent systems burn ~15x the tokens of chat — the architect must justify that cost and only fan out when the task value warrants it.
- Build in checkpoints where a human can inspect intermediate outputs.

## Mandatory two-phase execution model for every generated workflow

Every workflow the architect produces MUST follow this lifecycle:

### Phase 1 — Plan (gated)

- The workflow's entry slash command always starts in plan mode (`permission-mode: plan` in the command frontmatter, or an explicit EnterPlanMode step) — never in execution mode.
- In this phase the orchestrator does read-only discovery, then presents: the step-by-step execution plan, which subagents will run, what files/directories will be created or modified, what commands will be executed, and the estimated scope of changes.
- Execution must not begin until I explicitly approve the plan. Approval of the plan is the single human gate for the run.

### Phase 2 — Execute (autonomous)

- Only after plan approval does the workflow proceed under `--dangerously-skip-permissions` / bypassPermissions so it can run uninterrupted.
- The generated README must document the exact invocation pattern (e.g. run the planning command in a normal session, then relaunch or continue with `claude --dangerously-skip-permissions` once the plan is approved — use whatever mechanism current Claude Code docs recommend for this handoff; verify against the docs).
- The execution phase must be self-constraining because permissions are off:
  - Hard-scope all writes to the project directory and the `.workflow/` scratch directory — never `$HOME`, system paths, or unrelated repos
  - No destructive git operations (force push, `reset --hard`, branch deletion) and no `rm -rf` outside `.workflow/`
  - No network calls or package installs unless they were explicitly listed in the approved plan
  - Any action outside the approved plan's stated scope requires stopping and re-entering plan mode, not improvising
- Where appropriate, generate a PreToolUse hook or settings snippet that enforces these boundaries mechanically rather than relying on prompt instructions alone.
- The README must include a warning that skip-permissions mode is safest inside a container/VM or dedicated sandbox directory, per Anthropic's guidance.

## What the agent does

When I give it a task, it acts as an expert in multi-agent orchestration and:

1. **Runs a structured discovery interview before designing anything.** It should ask me about:
   - The task's inputs, outputs, and success criteria
   - Which steps are parallelizable vs. sequential
   - Which steps need heavy reasoning (Fable/Opus-class) vs. cheap execution (Haiku-class)
   - Tool/permission needs per step (file access, web, bash, MCP servers)
   - The blast radius I'm comfortable with in the autonomous execution phase (which dirs are writable, whether network/installs are allowed)
   - How often I'll reuse this workflow and how it should be parameterized

   It asks questions in small batches (max 3-4 at a time), skips questions it can infer from my task description, and confirms its understanding before designing.

2. **Recommends the right architecture per Anthropic's guidance** — including telling me when a single agent or simple prompt chain is better than a multi-agent system — and only then produces the workflow.

3. **Produces a complete, reusable workflow as artifacts, not just a description:**
   - Subagent definition files (`~/.claude/agents/*.md`) for each specialist agent, with narrow tool allowlists and the cheapest model that can do the job
   - A slash command (`~/.claude/commands/*.md`) that orchestrates them, parameterized with `$ARGUMENTS`, implementing the two-phase plan→execute lifecycle above
   - Any hooks/settings snippets needed to enforce execution-phase boundaries
   - A short README explaining how to invoke it (both phases), what each agent does, the orchestration pattern used and why, the data flow between them, and the safety scope

4. **Optimizes for token usage, memory, and context window by design:**
   - Assigns per-step model tiers (don't use Fable for grep-level work)
   - Keeps each subagent's context isolated — pass only distilled summaries/handoff files between agents, never full transcripts
   - Uses the filesystem as shared memory (e.g. a `.workflow/` scratch directory with structured handoff files) instead of stuffing everything into one context window
   - Persists the approved plan to `.workflow/plan.md` so the execution phase works from the plan file, not a re-derivation
   - Instructs agents to read files selectively (targeted views, grep) rather than whole-repo dumps
   - Prefers parallel fan-out with a cheap synthesizer over long sequential chains where possible
   - Includes explicit context-budget guidance in each agent's prompt (what to include, what to summarize, what to drop)
   - Uses compaction/summarization checkpoints for long-running workflows

## Constraints

- Everything must live in my user-level `~/.claude/` directory so it works in any project/session
- Follow current Claude Code conventions for subagent frontmatter (name, description, tools, model) and permission modes — check the docs if unsure
- The architect agent itself should be `model: claude-fable-5`; the workflows it generates should use tiered models

## Plan mode instructions

In your plan, show me: the file tree you'll create, the architect agent's full system prompt outline (including how it encodes the Anthropic principles and the two-phase lifecycle), the interview question framework, the hook/settings enforcement approach, and the template it will use for generated workflows. Wait for my approval before writing files.
