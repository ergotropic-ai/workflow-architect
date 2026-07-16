#!/usr/bin/env bash
# ci.sh -- the single test harness. CI picks the configuration (via the env
# contract below); this script does the work, so it is runnable locally too:
#
#   bash tests/ci.sh
#
# It probes for optional tools rather than requiring them: a missing tool is a
# LOUD, COUNTED skip with a reason, never a silent pass.
#
# Env contract -- a job DECLARES the configuration it exists to exercise, and
# this harness FAILS if reality does not match. A job that removes jq to test
# the shim path must not silently degrade into a duplicate of the jq job and
# report a green tick that proves nothing.
#
#   WFA_EXPECT_JQ=present|absent   assert real jq is/is not on PATH
#   WFA_EXPECT_SH=dash|bash        assert /bin/sh is the named shell
#   WFA_EXPECT_PS=51|core|none     assert which PowerShell engines exist
#   WFA_EXPECT_BASH_SUITE=<n>      assert the bash suite counts exactly n tests
#   WFA_EXPECT_PS_SUITE=<n>        assert the ps suite counts exactly n tests
#
# Exit code: 1 if any counted check fails or any precondition is violated.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; SKIP=0
FAILURES=""; SKIPS=""

ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); FAILURES="${FAILURES}  - ${1} :: ${2}"$'\n'; echo "  [FAIL] $1 -- $2"; }
skip() { SKIP=$((SKIP+1)); SKIPS="${SKIPS}  - ${1} :: ${2}"$'\n'; echo "  [SKIP] $1 -- $2"; }
chk()  { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2" "$3"; fi; }
fatal() { echo ""; echo "PRECONDITION VIOLATED: $1"; echo "This job exists to exercise a specific configuration and that configuration"; echo "is not in place. Refusing to run and report a green tick that proves nothing."; exit 1; }

# Portable path for tools that are not POSIX-aware (PowerShell on Windows).
# C:/foo/bar is understood by both Git Bash and PowerShell.
winpath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# ===========================================================================
# Environment banner -- the log must prove which configuration ran.
# ===========================================================================
UNAME_S="$(uname -s)"; UNAME_M="$(uname -m)"
case "$UNAME_S" in MINGW*|MSYS*|CYGWIN*) HOST_OS=windows ;; Darwin) HOST_OS=macos ;; Linux) HOST_OS=linux ;; *) HOST_OS="$UNAME_S" ;; esac

JQ_PATH="$(command -v jq 2>/dev/null || true)"
if [ -n "$JQ_PATH" ]; then
  JQ_STATE=present; JQ_DESC="$JQ_PATH ($(jq --version 2>/dev/null || echo '?'))"
  GUARD_PATH_SEL="real jq"
else
  JQ_STATE=absent; JQ_DESC="ABSENT"
  # Probe the shim with a filter it actually implements -- it exits 3 on
  # anything else (including --version), so a flag probe would misreport the
  # shim as unusable and make this banner lie about the path being taken.
  if [ "$(printf '{"tool_name":"probe"}' | "$REPO/tests/bin/jq" -r '.tool_name // empty' 2>/dev/null)" = "probe" ]; then
    GUARD_PATH_SEL="tests/bin python shim (real jq absent)"
  else
    GUARD_PATH_SEL="NEITHER jq nor python -- guard must fail closed"
  fi
fi

SH_REAL="unknown"
if [ -e /bin/sh ]; then
  SH_REAL="$(/bin/sh -c 'echo ${BASH_VERSION:+bash}' 2>/dev/null)"
  [ -z "$SH_REAL" ] && SH_REAL="not-bash(likely dash)" || SH_REAL="bash"
fi

PY_PATH=""
for p in python3 python py; do if command -v "$p" >/dev/null 2>&1 && "$p" -c '' >/dev/null 2>&1; then PY_PATH="$p ($("$p" -V 2>&1))"; break; fi; done
[ -z "$PY_PATH" ] && PY_PATH="ABSENT"

# Probe every PowerShell engine present. 5.1 and 7 are different engines and the
# guard's worst historical defect ($input as an automatic variable) reproduced
# ONLY on 5.1 -- so both are run when both exist.
PS_ENGINES=""; PS_DESC=""
for e in powershell pwsh; do
  command -v "$e" >/dev/null 2>&1 || continue
  v="$("$e" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
  [ -z "$v" ] && continue
  PS_ENGINES="$PS_ENGINES $e"; PS_DESC="$PS_DESC $e=$v"
done
[ -z "$PS_DESC" ] && PS_DESC=" ABSENT"

echo "==========================================================================="
echo " workflow-architect CI harness"
echo "==========================================================================="
echo " OS / arch      : $HOST_OS ($UNAME_S $UNAME_M)"
echo " bash           : ${BASH_VERSION:-?}"
echo " /bin/sh is     : $SH_REAL"
echo " dash           : $(command -v dash 2>/dev/null || echo ABSENT)"
echo " jq             : $JQ_DESC"
echo " python         : $PY_PATH"
echo " PowerShell     :$PS_DESC"
echo " git            : $(git --version 2>/dev/null || echo ABSENT)"
echo "---------------------------------------------------------------------------"
echo " GUARD CODE PATH SELECTED: $GUARD_PATH_SEL"
echo " Declared: JQ=${WFA_EXPECT_JQ:-<unset>} SH=${WFA_EXPECT_SH:-<unset>} PS=${WFA_EXPECT_PS:-<unset>}"
echo "==========================================================================="

# ===========================================================================
# Preconditions -- assert the declared configuration is actually in place.
# ===========================================================================
if [ -n "${WFA_EXPECT_JQ:-}" ] && [ "$WFA_EXPECT_JQ" != "$JQ_STATE" ]; then
  fatal "expected real jq to be $WFA_EXPECT_JQ, but it is $JQ_STATE ($JQ_DESC)"
fi
if [ -n "${WFA_EXPECT_SH:-}" ]; then
  case "$WFA_EXPECT_SH:$SH_REAL" in
    bash:bash) ;;
    dash:not-bash*) ;;
    *) fatal "expected /bin/sh to be $WFA_EXPECT_SH, but it is $SH_REAL" ;;
  esac
fi
if [ -n "${WFA_EXPECT_PS:-}" ]; then
  case "$WFA_EXPECT_PS" in
    51)   echo "$PS_DESC" | grep -q 'powershell=5\.1' || fatal "expected Windows PowerShell 5.1; engines found:$PS_DESC" ;;
    core) echo "$PS_DESC" | grep -q 'pwsh=[7-9]'      || fatal "expected pwsh 7+; engines found:$PS_DESC" ;;
    none) [ -z "$PS_ENGINES" ]                        || fatal "expected no PowerShell; engines found:$PS_DESC" ;;
  esac
fi

# ===========================================================================
# [K] Packaging -- what breaks on other people's machines, never the author's.
# Tested against a CLEAN CLONE, because that is what other people actually get:
# .gitattributes normalization applied, exec bits as recorded in the index.
# ===========================================================================
echo ""
echo "=== [K] Packaging (clean clone) ==="

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wfaci)"
trap 'rm -rf "$TMP"' EXIT
CLONE="$TMP/clone"
if git clone -q "$REPO" "$CLONE" 2>/dev/null; then
  ok "clean clone of the repo succeeds"

  # Files .gitattributes pins to LF. A CRLF here means the script does not run.
  # Only the pinned set is checked: everything else deliberately follows
  # core.autocrlf, so asserting LF on e.g. *.ps1 would test a rule that does
  # not exist.
  CRLF_BAD=""
  for f in $(cd "$CLONE" && git ls-files '*.sh' '*.sh.tmpl' 'tests/bin/jq' 'tests/bin/jq_shim.py'); do
    if grep -q $'\r' "$CLONE/$f" 2>/dev/null; then CRLF_BAD="$CRLF_BAD $f"; fi
  done
  chk "$([ -z "$CRLF_BAD" ] && echo 0 || echo 1)" \
      "LF-pinned files have no CRLF in a clean checkout" "CRLF found in:$CRLF_BAD"

  BOM_BAD=""
  for f in $(cd "$CLONE" && git ls-files); do
    [ -f "$CLONE/$f" ] || continue
    if [ "$(head -c 3 "$CLONE/$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then BOM_BAD="$BOM_BAD $f"; fi
  done
  chk "$([ -z "$BOM_BAD" ] && echo 0 || echo 1)" "no committed file carries a UTF-8 BOM" "BOM found in:$BOM_BAD"

  # Exec bit is a property of the git index, so it is asserted on every OS.
  for f in install.sh tests/bin/jq; do
    mode="$(cd "$CLONE" && git ls-files -s "$f" | awk '{print $1}')"
    chk "$([ "$mode" = "100755" ] && echo 0 || echo 1)" "$f is mode 100755 in the index" "mode is '$mode', not 100755"
  done

  # The bit surviving to the filesystem is a POSIX-only guarantee: Windows
  # checkouts set core.filemode=false and cannot represent it. Not a gap in
  # coverage -- the index assertion above is the portable contract, and the
  # ubuntu/macos runs prove the filesystem side.
  if [ "$HOST_OS" = "windows" ]; then
    skip "install.sh is executable on disk after clone" "Windows checkouts cannot represent the exec bit (core.filemode=false); the index-mode check above is the portable assertion, and ubuntu/macos prove the on-disk side"
  else
    chk "$([ -x "$CLONE/install.sh" ] && echo 0 || echo 1)" "install.sh is executable on disk after clone" "not executable"
  fi

  # gitattributes must actually resolve, not merely exist.
  attr="$(cd "$CLONE" && git check-attr eol -- install.sh 2>/dev/null | sed 's/.*: //')"
  chk "$([ "$attr" = "lf" ] && echo 0 || echo 1)" ".gitattributes resolves eol=lf for install.sh" "git check-attr says '$attr'"

  # Clean-clone smoke: the installer must work from a fresh clone, not just
  # from the author's working tree.
  SMOKE_HOME="$TMP/smoke-home"
  if (cd "$CLONE" && bash install.sh --claude-home "$SMOKE_HOME" >/dev/null 2>&1); then
    missing=""
    for f in agents/workflow-architect.md commands/design-workflow.md \
             skills/workflow-design/SKILL.md \
             skills/workflow-design/templates/workflow-guard.sh.tmpl; do
      [ -e "$SMOKE_HOME/$f" ] || missing="$missing $f"
    done
    chk "$([ -z "$missing" ] && echo 0 || echo 1)" "clean-clone smoke: install.sh lands the system files" "missing:$missing"
  else
    bad "clean-clone smoke: install.sh lands the system files" "install.sh failed from a clean clone"
  fi
else
  bad "clean clone of the repo succeeds" "git clone failed"
fi

# ===========================================================================
# [I] Installer contract
# ===========================================================================
echo ""
echo "=== [I] Installer contract ==="

DRY="$TMP/dry-home"
bash "$REPO/install.sh" --claude-home "$DRY" --dry-run >/dev/null 2>&1
chk "$([ ! -e "$DRY" ] && echo 0 || echo 1)" "install.sh --dry-run writes nothing" "$DRY was created by a dry run"

BAK="$TMP/bak-home"
bash "$REPO/install.sh" --claude-home "$BAK" >/dev/null 2>&1
echo 'sentinel' > "$BAK/agents/workflow-architect.md"
bash "$REPO/install.sh" --claude-home "$BAK" >/dev/null 2>&1
if [ -f "$BAK/agents/workflow-architect.md.bak" ] && grep -q sentinel "$BAK/agents/workflow-architect.md.bak"; then
  ok "install.sh backs the previous file up to .bak before overwriting"
else
  bad "install.sh backs the previous file up to .bak before overwriting" "no .bak, or .bak does not hold the previous content"
fi

bash "$REPO/install.sh" --claude-home "$TMP/badopt" --nonsense >/dev/null 2>&1
chk "$([ $? -ne 0 ] && echo 0 || echo 1)" "install.sh rejects an unknown option (non-zero exit)" "accepted an unknown option"

# install.ps1 is the Windows peer; run it wherever a PowerShell engine exists.
PS1_ENGINE=""
for e in $PS_ENGINES; do PS1_ENGINE="$e"; done
if [ -n "$PS1_ENGINE" ]; then
  WHATIF="$TMP/whatif-home"
  "$PS1_ENGINE" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$REPO/install.ps1")" \
      -ClaudeHome "$(winpath "$WHATIF")" -WhatIf >/dev/null 2>&1
  chk "$([ ! -e "$WHATIF/agents" ] && echo 0 || echo 1)" "install.ps1 -WhatIf writes nothing ($PS1_ENGINE)" "$WHATIF/agents was created by -WhatIf"

  PSHOME_T="$TMP/ps-home"
  "$PS1_ENGINE" -NoProfile -ExecutionPolicy Bypass -File "$(winpath "$REPO/install.ps1")" \
      -ClaudeHome "$(winpath "$PSHOME_T")" >/dev/null 2>&1
  chk "$([ -e "$PSHOME_T/skills/workflow-design/SKILL.md" ] && echo 0 || echo 1)" "install.ps1 installs the skill pack ($PS1_ENGINE)" "SKILL.md not found under $PSHOME_T"
else
  skip "install.ps1 -WhatIf writes nothing" "no PowerShell engine on this host"
  skip "install.ps1 installs the skill pack" "no PowerShell engine on this host"
fi

# ===========================================================================
# Install the system under test, then run both suites against it.
# ===========================================================================
CH="$TMP/claude-home"
bash "$REPO/install.sh" --claude-home "$CH" >/dev/null 2>&1 || { echo "FATAL: install.sh failed"; exit 1; }

# ===========================================================================
# [G] Bash guard suite
# ===========================================================================
echo ""
echo "=== [G] Bash guard suite (tests/run-guard-tests.sh) ==="
GOUT="$TMP/guard-out.txt"
CLAUDE_HOME="$CH" bash "$REPO/tests/run-guard-tests.sh" > "$GOUT" 2>&1; GEC=$?
sed 's/^/  | /' "$GOUT"

G_PASS="$(sed -n 's/^Tests:[[:space:]]*\([0-9]*\) passed.*/\1/p' "$GOUT" | tail -1)"
G_FAIL="$(sed -n 's/^Tests:.*, \([0-9]*\) failed.*/\1/p' "$GOUT" | tail -1)"
G_WARN="$(sed -n 's/^Warnings:[[:space:]]*\([0-9]*\).*/\1/p' "$GOUT" | tail -1)"
G_PASS="${G_PASS:-0}"; G_FAIL="${G_FAIL:-0}"; G_WARN="${G_WARN:-0}"

chk "$GEC" "bash guard suite exits 0" "exit code $GEC; ${G_FAIL} test(s) failed"

# Every WARN the suite emits is a skipped assertion. Surface each one here so it
# is counted in this harness's summary rather than scrolling past as log noise.
if [ "$G_WARN" -gt 0 ]; then
  while IFS= read -r w; do
    name="$(printf '%s' "$w" | sed 's/^[[:space:]]*-[[:space:]]*//; s/ :: .*//')"
    why="$(printf '%s' "$w" | sed 's/.* :: //')"
    skip "guard suite: $name" "$why"
  done < <(sed -n '/^Hardening warnings:/,$p' "$GOUT" | sed -n 's/^  - /  - /p')
fi

# The count is the anti-theatre check: a suite that silently stops running cases
# still exits 0. Pin the number so a vanished test is a red build.
#
# The invariant is pass+warn, not pass: the suite degrades an assertion to a
# warning when the shell it needs is absent (no dash on macOS), so the passing
# count is legitimately host-dependent while the number of assertions ATTEMPTED
# is not. Pinning the total catches a test that silently stopped running; the
# warn count is surfaced as a skip above so a degraded assertion never reads as
# a pass.
if [ -n "${WFA_EXPECT_BASH_SUITE:-}" ]; then
  G_TOTAL=$((G_PASS + G_WARN))
  chk "$([ "$G_TOTAL" = "$WFA_EXPECT_BASH_SUITE" ] && echo 0 || echo 1)" \
      "bash guard suite attempted exactly $WFA_EXPECT_BASH_SUITE assertions" \
      "expected $WFA_EXPECT_BASH_SUITE assertions, counted $G_TOTAL ($G_PASS passed + $G_WARN warned) -- a test may have silently stopped running"
fi

# ===========================================================================
# [P] PowerShell suite -- run under EVERY engine present.
# ===========================================================================
echo ""
echo "=== [P] PowerShell suite (tests/run-tests.ps1) ==="
if [ -z "$PS_ENGINES" ]; then
  skip "PowerShell suite (run-tests.ps1)" "no powershell/pwsh on this host; the ubuntu+macos pwsh jobs and the windows 5.1 job cover this suite"
else
  for e in $PS_ENGINES; do
    ver="$("$e" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null | tr -d '\r')"
    echo "  --- engine: $e ($ver) ---"
    POUT="$TMP/ps-out-$e.txt"
    CLAUDE_HOME="$(winpath "$CH")" "$e" -NoProfile -ExecutionPolicy Bypass \
        -File "$(winpath "$REPO/tests/run-tests.ps1")" > "$POUT" 2>&1; PEC=$?
    sed 's/^/  | /' "$POUT"
    P_PASS="$(sed -n 's/^Tests:[[:space:]]*\([0-9]*\) passed.*/\1/p' "$POUT" | tail -1)"
    P_PASS="${P_PASS:-0}"
    chk "$PEC" "ps suite exits 0 under $e $ver" "exit code $PEC"
    if [ -n "${WFA_EXPECT_PS_SUITE:-}" ]; then
      chk "$([ "$P_PASS" = "$WFA_EXPECT_PS_SUITE" ] && echo 0 || echo 1)" \
          "ps suite ran exactly $WFA_EXPECT_PS_SUITE tests under $e" \
          "expected $WFA_EXPECT_PS_SUITE passing tests, counted $P_PASS"
    fi
  done
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==========================================================================="
echo " SUMMARY -- $HOST_OS / jq=$JQ_STATE / sh=$SH_REAL"
echo " Guard code path exercised: $GUARD_PATH_SEL"
echo "---------------------------------------------------------------------------"
echo " harness checks : $PASS passed, $FAIL failed, $SKIP skipped"
echo " bash suite     : $G_PASS passed, $G_FAIL failed, $G_WARN warned"
echo "==========================================================================="
if [ -n "$FAILURES" ]; then echo ""; echo "FAILED:"; printf '%s' "$FAILURES"; fi
if [ -n "$SKIPS" ]; then
  echo ""
  echo "SKIPPED (each is an assertion NOT made -- a skip is not a pass):"
  printf '%s' "$SKIPS"
fi
echo ""
[ "$FAIL" -eq 0 ] || exit 1
exit 0
