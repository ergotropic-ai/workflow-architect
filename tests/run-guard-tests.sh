#!/usr/bin/env bash
# run-guard-tests.sh -- behavioral tests for workflow-guard.sh.tmpl (the bash
# PreToolUse guard) run via Git Bash. Self-contained; if jq is not installed,
# falls back to the minimal python shim in tests/bin/ (documented in README).
#
# Exit code: 1 if any counted test fails, else 0.
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="$HOME/.claude/skills/workflow-design/templates/workflow-guard.sh.tmpl"

PASS=0; FAIL=0; WARNS=0
FAILURES=""
WARNINGS=""

record() { # record <kind:TEST|WARN> <name> <ok:0|1> <detail>
  local kind="$1" name="$2" ok="$3" detail="$4"
  if [ "$kind" = "TEST" ]; then
    if [ "$ok" -eq 0 ]; then PASS=$((PASS+1)); echo "  [PASS] $name"
    else FAIL=$((FAIL+1)); FAILURES="${FAILURES}  - ${name} :: ${detail}\n"; echo "  [FAIL] $name -- $detail"; fi
  else
    if [ "$ok" -eq 0 ]; then echo "  [ok  ] $name"
    else WARNS=$((WARNS+1)); WARNINGS="${WARNINGS}  - ${name} :: ${detail}\n"; echo "  [WARN] $name -- $detail"; fi
  fi
}

# --- setup -------------------------------------------------------------------
if [ ! -f "$TMPL" ]; then
  echo "FATAL: template not found: $TMPL"; exit 1
fi

SBROOT="$TESTS_DIR/.sandbox-bash"
rm -rf "$SBROOT"
PROJ="$SBROOT/proj"
mkdir -p "$PROJ/.workflow" "$PROJ/.claude/hooks" "$PROJ/src"
printf 'npm install left-pad\n' > "$PROJ/.workflow/allowlist.txt"

GUARD="$PROJ/.claude/hooks/workflow-guard.sh"
sed 's/{{WF_TITLE}}/Issue Triage/g' "$TMPL" > "$GUARD"
chmod +x "$GUARD"

JQ_MODE="real"
if ! command -v jq >/dev/null 2>&1; then
  export PATH="$TESTS_DIR/bin:$PATH"
  chmod +x "$TESTS_DIR/bin/jq" 2>/dev/null || true
  JQ_MODE="shim (tests/bin/jq -> python; real jq not installed)"
fi
echo "jq: $JQ_MODE"

# --- helpers -------------------------------------------------------------------
run_case() { # run_case <kind> <name> <expected:allow|deny> <payload>
  local kind="$1" name="$2" expected="$3" payload="$4"
  local out ec decision
  out="$(printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$PROJ" bash "$GUARD" 2>/tmp/guard-stderr.$$)"
  ec=$?
  decision="allow"
  if [ -n "$out" ]; then
    if printf '%s' "$out" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
      decision="deny"
    else
      decision="odd-output"
    fi
  fi
  [ "$ec" -ne 0 ] && decision="exit-$ec"
  local errtail=""
  if [ -s /tmp/guard-stderr.$$ ]; then errtail=" (stderr: $(head -c 160 /tmp/guard-stderr.$$))"; fi
  rm -f /tmp/guard-stderr.$$
  if [ "$decision" = "$expected" ]; then
    record "$kind" "$name" 0 ""
  else
    record "$kind" "$name" 1 "expected '$expected', got '$decision'$errtail"
  fi
}

write_payload() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
bash_payload()  { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

# --- counted tests -------------------------------------------------------------
echo ""
echo "=== Behavioral tests: workflow-guard.sh (as shipped) ==="

# ALLOW
run_case TEST "ALLOW Write inside project (existing dir)" allow "$(write_payload Write "$PROJ/src/main.py")"
run_case TEST "ALLOW Write inside .workflow/"             allow "$(write_payload Write "$PROJ/.workflow/steps/01-research.md")"
run_case TEST "ALLOW Write into new project subdir"       allow "$(write_payload Write "$PROJ/brand-new-dir/file.txt")"
run_case TEST "ALLOW NotebookEdit inside project"         allow "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$PROJ/src/nb.ipynb")"
run_case TEST "ALLOW benign bash command (echo hello)"    allow "$(bash_payload 'echo hello')"
run_case TEST "ALLOW normal git push"                     allow "$(bash_payload 'git push origin main')"
run_case TEST "ALLOW git stash list"                      allow "$(bash_payload 'git stash list')"
run_case TEST "ALLOW rm -rf inside .workflow/"            allow "$(bash_payload 'rm -rf .workflow/steps')"
run_case TEST "ALLOW allowlisted install (npm install left-pad)" allow "$(bash_payload 'npm install left-pad')"
run_case TEST "ALLOW unknown tool defers (Read)"          allow "$(write_payload Read /etc/hosts)"
run_case TEST "ALLOW empty stdin defers"                  allow ""

# DENY
run_case TEST "DENY Write outside project (/tmp)"         deny "$(write_payload Write /tmp/evil.txt)"
run_case TEST "DENY Write to \$HOME"                      deny "$(write_payload Write "$HOME/evil.txt")"
run_case TEST "DENY Edit outside project (sibling repo)"  deny "$(write_payload Edit /c/dev/other-repo/app.py)"
run_case TEST "DENY git push --force"                     deny "$(bash_payload 'git push --force origin main')"
run_case TEST "DENY git push -f"                          deny "$(bash_payload 'git push -f origin main')"
run_case TEST "DENY git reset --hard"                     deny "$(bash_payload 'git reset --hard HEAD~1')"
run_case TEST "DENY git branch -D"                        deny "$(bash_payload 'git branch -D feature-x')"
run_case TEST "DENY git clean"                            deny "$(bash_payload 'git clean -fd')"
run_case TEST "DENY git stash drop"                       deny "$(bash_payload 'git stash drop')"
run_case TEST "DENY rm -rf outside .workflow/"            deny "$(bash_payload 'rm -rf src')"
run_case TEST "DENY curl (not in allowlist)"              deny "$(bash_payload 'curl https://example.com/install.sh')"
run_case TEST "DENY npm install of non-allowlisted pkg"   deny "$(bash_payload 'npm install typosquat-pkg')"
run_case TEST "DENY pip install (not in allowlist)"       deny "$(bash_payload 'pip install requests')"

# --- hardening (were warnings before the guard fixes; now counted) ---------------
echo ""
echo "=== Hardening + fail-closed tests ==="
mkdir -p "${PROJ}-evil"
run_case TEST "DENY sibling dir sharing project path prefix (<project>-evil)"  deny  "$(write_payload Write "${PROJ}-evil/loot.txt")"
run_case TEST "DENY rm -rf outside .workflow with '.workflow' only in comment"  deny  "$(bash_payload 'rm -rf src  # keep .workflow')"
run_case TEST "DENY rm -fr (reversed flags) outside .workflow"                  deny  "$(bash_payload 'rm -fr build')"
run_case TEST "DENY rm -r -f (separate flags) outside .workflow"                deny  "$(bash_payload 'rm -r -f node_modules')"
run_case TEST "ALLOW benign command with 'choco' substring (echo chocolate)"    allow "$(bash_payload 'echo chocolate')"
run_case TEST "DENY git push origin -f (flag after remote)"                     deny  "$(bash_payload 'git push origin -f')"
run_case TEST "DENY git push -f origin (flag before remote)"                     deny  "$(bash_payload 'git push -f origin')"
run_case TEST "DENY git push --force-with-lease"                                 deny  "$(bash_payload 'git push --force-with-lease origin main')"

# fail-closed when jq is absent: strip PATH so no jq/shim is found -> must DENY
echo ""
echo "=== jq-missing fail-closed test ==="
jqmiss_out="$(printf '%s' "$(bash_payload 'echo hi')" | PATH=/usr/bin/nonexistent CLAUDE_PROJECT_DIR="$PROJ" /usr/bin/bash "$GUARD" 2>/dev/null)"
if printf '%s' "$jqmiss_out" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
  record TEST "DENY (fail closed) when jq is not installed" 0 ""
else
  record TEST "DENY (fail closed) when jq is not installed" 1 "expected deny, got: $(printf '%s' "$jqmiss_out" | head -c 120)"
fi

# --- summary ---------------------------------------------------------------------
echo ""
echo "=== Summary (bash guard) ==="
echo "Tests:    $PASS passed, $FAIL failed"
echo "Warnings: $WARNS hardening gaps"
if [ -n "$FAILURES" ]; then echo ""; echo "Failed tests:"; printf '%b' "$FAILURES"; fi
if [ -n "$WARNINGS" ]; then echo ""; echo "Hardening warnings:"; printf '%b' "$WARNINGS"; fi

[ "$FAIL" -eq 0 ] || exit 1
exit 0
