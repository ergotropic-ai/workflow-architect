# workflow-architect test suite

Tests for the workflow-architect system installed under `~/.claude`
(agent + slash command + workflow-design skill + templates + guard hooks).
The suite is self-contained: no Pester, no package installs. Set
`CLAUDE_HOME` to test a different install root.

## How to run

PowerShell suite (static/structural tests + PowerShell guard behavior;
Windows PowerShell 5.1 or pwsh on any OS):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-tests.ps1
```

Bash guard suite (any bash; Git Bash on Windows):

```bash
bash tests/run-guard-tests.sh
```

Both exit `1` if any counted test fails. Both recreate their scratch
sandboxes (`tests/.sandbox/`, `tests/.sandbox-bash/`) on every run; the
sandboxes can be deleted at any time.

## What each part covers

### `run-tests.ps1`

- **[S] Static / structural**
  - All 14 system files exist.
  - YAML frontmatter of `agents/workflow-architect.md`,
    `commands/design-workflow.md`, and `skills/workflow-design/SKILL.md`
    parses (a small YAML-subset validator covering exactly the constructs
    those files use: scalars, quoted values, `>`/`|` block scalars, lists,
    nested maps; rejects tabs and keyless lines).
  - The `@~/.claude/agents/...` include target referenced by
    `design-workflow.md` exists on disk.
  - Every `{{TOKEN}}` in every `*.tmpl` is well-formed (`{{UPPER_SNAKE}}`,
    no orphan/unclosed `{{`/`}}`), is documented in `SKILL.md`, and every
    documented token is used by at least one template.
  - After substituting a full set of sample values, no residual tokens
    remain in any template.
  - `settings-snippet.json.tmpl` is valid JSON after substitution, has a
    non-empty `permissions.deny`, registers `PreToolUse` hooks, and the
    hook commands reference the substituted guard filename.
  - The four markdown templates' frontmatter parses after substitution.
- **[P] Portability** — a generated workflow gets committed and cloned onto
  other OSes, so no rendered artifact may encode the generating host. Checks
  that no OS-conditional token (`{{GUARD_HOOK}}`/`{{SHELL}}`) survives, that
  every hook entry pins `"shell": "bash"` at `workflow-guard.sh` through an
  explicit `bash` wrapper, that hook paths use `${CLAUDE_PROJECT_DIR}` with
  forward slashes, that rendering is deterministic, and that the generated
  README documents the `.sh` guard and its `jq` requirement. The `Bash|PowerShell`
  matcher and the `PowerShell(...)` deny rule are asserted to *remain* — which
  tool Claude may invoke depends on the running host, not the generating one.
- **[B] Behavioral: `workflow-guard.ps1` fallback as shipped** (rendered from the
  template into a sandbox project with an allowlist containing
  `npm install left-pad`; payloads are fed on stdin exactly as Claude Code
  hooks deliver them, with `CLAUDE_PROJECT_DIR` pointing at the sandbox):
  - ALLOW: writes inside the project / `.workflow/` / a new subdir, benign
    bash, normal `git push`, `git stash list`, `rm -rf` inside
    `.workflow/`, an allowlisted install, unknown tools, empty stdin,
    malformed JSON.
  - DENY: writes to `$HOME` / system paths / sibling repos,
    `git push --force`, `git push -f`, `git reset --hard`,
    `git branch -D`, `git clean`, `git stash drop`, `rm -rf` outside
    `.workflow/`, `Remove-Item -Recurse -Force` outside `.workflow/`,
    `curl`, non-allowlisted `npm install`, `pip install`.
Sections `[D]` (diagnostic re-run against a patched guard) and `[W]`
(hardening probes as warnings) no longer exist. They were scaffolding for
diagnosing the defects listed below; once those were fixed, their cases
became ordinary counted `[B]` tests. The `Record` helper still accepts
`DIAG`/`WARN` kinds, but nothing calls them.

### `run-guard-tests.sh`

The same ALLOW/DENY matrix (plus the same hardening probes) against
`workflow-guard.sh.tmpl`, run under Git Bash — this is the guard that ships on
every OS. It closes with a portability section that parses the hook command out
of the *rendered settings snippet* and runs that exact string the way Claude Code
does (shell form, `sh -c`), under `sh`, `dash`, and `bash`, and again with the
guard's exec bit cleared. This is the test that would have caught the OS-leak
defect: the guard file being correct is worthless if the registration invoking it
is host-specific. The guard requires `jq`;
if `jq` is not installed the driver prepends `tests/bin/` to `PATH`, which
contains a minimal Python shim (`jq_shim.py`) supporting exactly the four
jq invocations the guard makes. The shim is a test-harness convenience
only — see the defect notes below.

### `bin/jq`, `bin/jq_shim.py`

The jq fallback shim described above. Used only when real jq is absent. The
wrapper runs whichever python interpreter the host has (`python3`, `python`,
or the Windows `py` launcher, in that order).

## Defects found by this suite, and fixed in the templates

All of the following were surfaced by this suite and have since been fixed
in `~/.claude/skills/workflow-design/templates/`. The tests
above now encode the corrected behavior and are the oracle for it.

1. **CRITICAL — `workflow-guard.ps1.tmpl` was a complete no-op.** It
   assigned parsed hook JSON to `$input`, a read-only PowerShell *automatic
   variable*; in Windows PowerShell 5.1 the assignment is silently
   discarded, so `$input.tool_name` was always null, no branch matched, and
   the guard allowed everything. Fixed by renaming to `$hookInput`.
2. **`workflow-guard.sh.tmpl` denied writes into not-yet-existing project
   subdirectories** (including `.workflow/steps/` itself) because
   `inside()` did `cd "$(dirname "$full")"`, which fails for new dirs.
   Fixed with a pure-string `normalize()` that resolves `.`/`..` without
   touching the filesystem.
3. **`workflow-guard.sh.tmpl` failed open when `jq` was missing** (exited
   127, which Claude Code treats as a non-blocking error and proceeds).
   Fixed to fail CLOSED: it now emits a deny decision (built without jq)
   when jq is absent.
4. Hardening (both guards): project confinement is now a path-boundary
   check (a sibling `<project>-evil` is denied); the `rm -rf` /
   `Remove-Item -Recurse -Force` exception now verifies each actual target
   resolves inside `.workflow/` (in any flag order: `-rf`, `-fr`, `-r -f`)
   rather than grepping for the substring `.workflow`; network/install
   matching uses token boundaries (`echo chocolate` no longer trips
   `choco`); force-push detection catches `-f` in any position plus
   `--force-with-lease`.

5. **The generated workflow encoded the generating machine's OS.** The
   architect emitted `"shell": "powershell"` and a `workflow-guard.ps1`
   command when it ran on Windows. That config gets committed; a teammate
   cloning on Linux got a hook that cannot execute — and per the hooks docs a
   hook that fails to spawn is a *non-blocking* error that Claude Code proceeds
   past, so the workflow lost its safety floor silently while its README still
   promised enforcement. Fixed by making the output OS-neutral: one
   `workflow-guard.sh`, always registered as `"shell": "bash"` with a
   `bash "<path>"` wrapper. The wrapper matters because shell form runs under
   `sh -c` on macOS/Linux and `sh` is dash on Debian/Ubuntu, which cannot parse
   the guard's bashisms; it also drops the dependency on the exec bit surviving
   a clone. The `.ps1` remains only as a local, uncommitted fallback for native
   Windows hosts with no Git Bash.

Note: one test-harness over-broad check was also corrected — the
placeholder-token validator flagged bare `}}`, which occurs legitimately in
the guards' deny-decision JSON. It now flags only unclosed `{{` (tokens
always open with `{{`).
