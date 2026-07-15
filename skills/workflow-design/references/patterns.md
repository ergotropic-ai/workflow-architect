# Pattern selection guide

Distilled from Anthropic's "Building Effective Agents" and "How we built our
multi-agent research system." Use it to pick the least complex structure that
solves the task.

## The core distinction

- **Workflows** orchestrate LLMs and tools through predefined code paths. Use
  them when the steps are predictable.
- **Agents** dynamically direct their own process and tool use. Use them when the
  required steps cannot be known in advance, and when success can be verified.

Prefer workflows when you can. Reach for an autonomous agent only when
flexibility and model-driven decision-making at scale are genuinely required —
you pay for it in latency, tokens, and failure surface.

## The simplicity ladder

1. **Single prompt** — augment one LLM call with retrieval, tools, and a
   verification instruction. Most tasks stop here.
2. **Single agent** — one LLM in a tool-use loop with a clear stopping check.
3. **Workflow** — one of the five patterns below.
4. **Autonomous multi-agent** — orchestrator plus workers with runtime-decided
   decomposition.

## The five composable patterns

### 1. Prompt chaining
Decompose into a fixed sequence; each step's output feeds the next. Optionally
gate between steps ("does this pass?"). Best when subtasks are fixed and known,
and accuracy matters more than latency. Example: draft copy → check against
constraints → translate.

### 2. Routing
Classify the input, then send it to a specialized handler. Best when there are
distinct categories that each want a different prompt or tool set, and
classification is reliable. Example: route support tickets by type; send cheap
queries to a small model and hard ones to a large one.

### 3. Parallelization
Run independent work simultaneously. Two flavors:
- **Sectioning**: split into independent subtasks run in parallel.
- **Voting**: run the same task several times for consensus or guardrails.
Best for independent subtasks, or when multiple perspectives raise confidence.
Parallel tool calls can cut wall-clock time dramatically.

### 4. Orchestrator-workers
A central LLM decomposes the task at runtime and delegates to workers, then
synthesizes their results. Best when you cannot predict the number or shape of
subtasks in advance (e.g. edits spanning an unknown set of files). Distinct from
parallelization: here the subtasks are decided by the model, not hard-coded.

### 5. Evaluator-optimizer
One LLM produces a result; another evaluates and gives feedback; iterate. Best
when clear evaluation criteria exist and iteration measurably improves output
(e.g. translation, complex search).

## When multi-agent is worth it

Multi-agent systems use roughly 15× the tokens of a plain chat (single agents
roughly 4×). They earn that cost mainly when the task:

- is heavily parallelizable,
- exceeds a single context window in the information it must touch, or
- involves many complex tool interfaces.

They are a **poor** fit when the task needs tightly shared context across all
agents, or has many interdependencies between subtasks — which describes most
single-repository coding. Recommend a single agent there.

Model choice is a bigger lever than token budget: upgrading the model tier of the
agent doing the reasoning often beats simply spending more tokens on a weaker
model. Tier deliberately.

## Delegation and effort scaling

Give every subagent an objective, an output format, tool/source guidance, and an
effort budget. Scale effort to complexity:

- Simple fact-finding → 1 agent, ~3–10 tool calls.
- Direct comparison → 2–4 subagents, ~10–15 calls each.
- Complex research → 10+ subagents with explicitly divided responsibilities.

Vague delegation ("research X") makes subagents duplicate each other's work and
leave gaps. Divide labor explicitly and tell each worker where its boundaries are.

## Tool-interface design

Invest in the agent-computer interface as much as the prompt. Give minimal tool
surfaces, unambiguous names and descriptions, and constraints that make misuse
hard (absolute paths, "read only these files," prefer search over full reads).
Poor tool descriptions send agents down wrong paths and waste tokens.
