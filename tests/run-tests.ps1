# run-tests.ps1 -- test suite for the workflow-architect system installed
# under ~/.claude (set CLAUDE_HOME to point elsewhere). Self-contained: no
# Pester, no installs. Runs under Windows PowerShell 5.1 or pwsh on any OS.
#
# Sections:
#   [S]  static / structural tests (frontmatter, JSON, token consistency)
#   [B]  behavioral tests of workflow-guard.ps1 (the system under test, as-is)
#   [D]  diagnostic re-run of [B] against a locally PATCHED copy of the guard
#        (isolates root cause; does NOT modify the system under test)
#   [W]  hardening probes (known-gap checks; reported as warnings, not failures)
#
# Exit code: 1 if any [S] or [B] test fails, else 0.

$ErrorActionPreference = 'Stop'

$ClaudeRoot = if ($env:CLAUDE_HOME) { $env:CLAUDE_HOME } else { Join-Path $HOME '.claude' }
$SkillDir   = Join-Path $ClaudeRoot 'skills/workflow-design'
$TmplDir    = Join-Path $SkillDir 'templates'
$TestsDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$IsWinHost  = ($env:OS -eq 'Windows_NT')
$PsExe      = (Get-Process -Id $PID).Path

$script:Pass = 0; $script:Fail = 0
$script:DiagPass = 0; $script:DiagFail = 0
$script:Warns = 0
$script:FailList = New-Object System.Collections.ArrayList
$script:WarnList = New-Object System.Collections.ArrayList

function Record([string]$kind, [string]$name, [bool]$ok, [string]$detail) {
    if ($kind -eq 'TEST') {
        if ($ok) { $script:Pass++; Write-Host "  [PASS] $name" }
        else {
            $script:Fail++
            [void]$script:FailList.Add("$name :: $detail")
            Write-Host "  [FAIL] $name -- $detail"
        }
    } elseif ($kind -eq 'DIAG') {
        if ($ok) { $script:DiagPass++; Write-Host "  [diag-pass] $name" }
        else { $script:DiagFail++; Write-Host "  [diag-FAIL] $name -- $detail" }
    } else {
        if ($ok) { Write-Host "  [ok  ] $name" }
        else {
            $script:Warns++
            [void]$script:WarnList.Add("$name :: $detail")
            Write-Host "  [WARN] $name -- $detail"
        }
    }
}

function ReadText([string]$path) {
    return [System.IO.File]::ReadAllText($path)
}

function Render([string]$text, [hashtable]$tokens) {
    foreach ($k in $tokens.Keys) {
        $text = $text.Replace('{{' + $k + '}}', [string]$tokens[$k])
    }
    return $text
}

# ---------------------------------------------------------------------------
# Minimal YAML-subset validator, covering the constructs these files use:
# scalars, quoted scalars, folded/literal block scalars (> / |), lists,
# nested maps by 2-space indentation. Rejects tabs, keyless lines, and
# structurally broken lines. Not a full YAML parser; adequate as a smoke
# check that frontmatter is well-formed.
# ---------------------------------------------------------------------------
function Get-Frontmatter([string]$text) {
    $lines = $text -split "`r?`n"
    if ($lines.Count -lt 3 -or $lines[0].Trim() -ne '---') { return $null }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq '---') {
            if ($i -eq 1) { return ,@() }
            return $lines[1..($i - 1)]
        }
    }
    return $null   # unterminated frontmatter
}

function Test-YamlBlock([string[]]$lines) {
    $errors = New-Object System.Collections.ArrayList
    $blockIndent = -1   # >= 0 while inside a > or | block scalar
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $line = $lines[$n]
        $lineNo = $n + 2   # +2: 1-based, plus the opening --- line
        if ($line -match "`t") {
            [void]$errors.Add("line ${lineNo}: tab character in YAML")
            continue
        }
        if ($blockIndent -ge 0) {
            if ($line.Trim() -eq '') { continue }
            $ind = $line.Length - $line.TrimStart(' ').Length
            if ($ind -gt $blockIndent) { continue }   # still inside the block scalar
            $blockIndent = -1                          # block ended; parse normally
        }
        $t = $line.Trim()
        if ($t -eq '') { continue }
        if ($t.StartsWith('#')) { continue }
        if ($line -match '^(\s*)-\s+(.+)$') {
            $itemIndent = $Matches[1].Length
            $item = $Matches[2]
            if ($item -match '^[A-Za-z_][\w.\-]*:\s*[>|][+\-]?\s*$') { $blockIndent = $itemIndent }
            continue
        }
        if ($line -match '^(\s*)([A-Za-z_][\w.\-]*):(\s.*|)$') {
            $keyIndent = $Matches[1].Length
            $val = $Matches[3].Trim()
            if ($val -match '^[>|][+\-]?$') { $blockIndent = $keyIndent }
            continue
        }
        [void]$errors.Add("line ${lineNo}: not a valid YAML mapping/list/scalar line: '$t'")
    }
    return $errors
}

function Check-Frontmatter([string]$name, [string]$text, [string[]]$requiredKeys) {
    $fm = Get-Frontmatter $text
    if ($null -eq $fm) {
        Record TEST "$name frontmatter present and terminated" $false 'missing or unterminated --- frontmatter block'
        return
    }
    Record TEST "$name frontmatter present and terminated" $true ''
    $errs = Test-YamlBlock $fm
    Record TEST "$name frontmatter parses as YAML (subset)" ($errs.Count -eq 0) ($errs -join '; ')
    $fmText = $fm -join "`n"
    foreach ($k in $requiredKeys) {
        $has = $fmText -match "(?m)^${k}:"
        Record TEST "$name frontmatter has key '$k'" $has "key '$k' missing"
    }
}

# ---------------------------------------------------------------------------
# Guard-hook invocation helper
# ---------------------------------------------------------------------------
function Invoke-Guard([string]$guardPath, [string]$projectDir, [string]$payload) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PsExe
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$guardPath`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = $projectDir
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($payload)
    $p.StandardInput.Close()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        Stdout   = $stdout.Trim()
        Stderr   = $stderr.Trim()
    }
}

function Get-GuardDecision($result) {
    if ($result.ExitCode -ne 0) { return "exit-$($result.ExitCode)" }
    if (-not $result.Stdout) { return 'allow' }
    try {
        $j = $result.Stdout | ConvertFrom-Json
        if ($j.hookSpecificOutput.permissionDecision -eq 'deny') { return 'deny' }
        return 'unexpected-json'
    } catch {
        return 'garbage-output'
    }
}

function New-Payload([string]$tool, [hashtable]$toolInput) {
    return (@{ tool_name = $tool; tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 5)
}

function Test-GuardCase([string]$kind, [string]$guard, [string]$proj,
                        [string]$name, [string]$expected, [string]$payload) {
    $r = Invoke-Guard $guard $proj $payload
    $decision = Get-GuardDecision $r
    $ok = ($decision -eq $expected)
    $detail = "expected '$expected', got '$decision'"
    if ($r.Stderr) { $detail += " (stderr: $($r.Stderr.Substring(0, [Math]::Min(160, $r.Stderr.Length))))" }
    Record $kind $name $ok $detail
}

# ===========================================================================
Write-Host ''
Write-Host '=== [S] Static / structural tests ==='

# --- S1: inventory ---------------------------------------------------------
$inventory = @(
    (Join-Path $ClaudeRoot 'agents/workflow-architect.md'),
    (Join-Path $ClaudeRoot 'commands/design-workflow.md'),
    (Join-Path $SkillDir 'SKILL.md'),
    (Join-Path $SkillDir 'references/patterns.md'),
    (Join-Path $SkillDir 'references/two-phase-lifecycle.md'),
    (Join-Path $SkillDir 'references/enforcement.md'),
    (Join-Path $TmplDir 'orchestrator-agent.md.tmpl'),
    (Join-Path $TmplDir 'worker-agent.md.tmpl'),
    (Join-Path $TmplDir 'plan-command.md.tmpl'),
    (Join-Path $TmplDir 'execute-command.md.tmpl'),
    (Join-Path $TmplDir 'settings-snippet.json.tmpl'),
    (Join-Path $TmplDir 'workflow-guard.ps1.tmpl'),
    (Join-Path $TmplDir 'workflow-guard.sh.tmpl'),
    (Join-Path $TmplDir 'README.md.tmpl')
)
$missing = @($inventory | Where-Object { -not (Test-Path $_) })
Record TEST 'all 14 system files exist' ($missing.Count -eq 0) ("missing: " + ($missing -join ', '))
if ($missing.Count -gt 0) { Write-Host 'Cannot continue without the system under test.'; exit 1 }

# --- S2: core-file frontmatter ----------------------------------------------
Check-Frontmatter 'agents/workflow-architect.md' (ReadText (Join-Path $ClaudeRoot 'agents/workflow-architect.md')) @('name', 'description', 'model')
Check-Frontmatter 'commands/design-workflow.md' (ReadText (Join-Path $ClaudeRoot 'commands/design-workflow.md')) @('description')
Check-Frontmatter 'skills/workflow-design/SKILL.md' (ReadText (Join-Path $SkillDir 'SKILL.md')) @('name', 'description')

# --- S3: the @-include target of the slash command exists -------------------
$cmdText = ReadText (Join-Path $ClaudeRoot 'commands/design-workflow.md')
$includeOk = $false
if ($cmdText -match '@~([^\s]+)') {
    $incPath = Join-Path $HOME ($Matches[1].TrimStart('/'))
    $includeOk = Test-Path $incPath
    Record TEST 'design-workflow.md @-include target exists' $includeOk "resolved '$incPath' not found"
} else {
    Record TEST 'design-workflow.md @-include target exists' $false 'no @~/... include reference found in the command'
}

# --- S4: token syntax validity in every template -----------------------------
$tmplFiles = Get-ChildItem $TmplDir -Filter '*.tmpl'
$validToken = '\{\{[A-Z][A-Z0-9_]*\}\}'
$allTemplateTokens = New-Object System.Collections.Generic.HashSet[string]

foreach ($tf in $tmplFiles) {
    $text = ReadText $tf.FullName
    $bad = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($text, '\{\{([^{}]*)\}\}')) {
        $inner = $m.Groups[1].Value
        if ($inner -notmatch '^[A-Z][A-Z0-9_]*$') { [void]$bad.Add($m.Value) }
        else { [void]$allTemplateTokens.Add($inner) }
    }
    # Placeholder tokens always OPEN with '{{'. After removing well-formed
    # tokens, any residual '{{' is an orphan/unclosed token. (We do NOT flag a
    # bare '}}' -- literal '}}' occurs legitimately in the guards' JSON/shell
    # bodies, e.g. the closing braces of the deny-decision JSON object.)
    $stripped = [regex]::Replace($text, $validToken, '')
    if ($stripped -match '\{\{') { [void]$bad.Add('orphan/unclosed {{ token sequence') }
    Record TEST "$($tf.Name): all placeholder tokens well-formed" ($bad.Count -eq 0) ("bad: " + ($bad -join ', '))
}

# --- S5: template tokens vs. SKILL.md documentation --------------------------
$skillText = ReadText (Join-Path $SkillDir 'SKILL.md')
$documented = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in [regex]::Matches($skillText, '\{\{([A-Z][A-Z0-9_]*)\}\}')) { [void]$documented.Add($m.Groups[1].Value) }

$undoc = @($allTemplateTokens | Where-Object { -not $documented.Contains($_) })
Record TEST 'every token used in templates is documented in SKILL.md' ($undoc.Count -eq 0) ("undocumented: " + ($undoc -join ', '))

$unused = @($documented | Where-Object { -not $allTemplateTokens.Contains($_) })
Record TEST 'every token documented in SKILL.md is used by some template' ($unused.Count -eq 0) ("documented but unused: " + ($unused -join ', '))

# --- S6: full sample substitution --------------------------------------------
$sample = @{
    WF               = 'triage'
    WF_TITLE         = 'Issue Triage'
    PARAMS           = '<issue-url>'
    AGENT_ROSTER     = '- triage-worker (sonnet, effort medium, maxTurns 15)'
    WORKER_NAME      = 'triage-worker'
    WORKER_MODEL     = 'sonnet'
    WORKER_EFFORT    = 'medium'
    WORKER_MAXTURNS  = '15'
    WORKER_TOOLS     = 'Read, Grep, Glob, Write'
    WORKER_OBJECTIVE = 'Investigate the issue and write findings to the step file.'
}

foreach ($tf in $tmplFiles) {
    $rendered = Render (ReadText $tf.FullName) $sample
    $leftover = [regex]::Matches($rendered, '\{\{[A-Z][A-Z0-9_]*\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique
    Record TEST "$($tf.Name): no residual tokens after full substitution" (@($leftover).Count -eq 0) ("residual: " + ($leftover -join ', '))
}

# --- S7: settings snippet is valid JSON after substitution -------------------
$settingsRendered = Render (ReadText (Join-Path $TmplDir 'settings-snippet.json.tmpl')) $sample
$settingsOk = $false; $settingsErr = ''
try { $settingsObj = $settingsRendered | ConvertFrom-Json; $settingsOk = $true } catch { $settingsErr = $_.Exception.Message }
Record TEST 'settings-snippet.json.tmpl: valid JSON after substitution' $settingsOk $settingsErr
if ($settingsOk) {
    Record TEST 'settings snippet: permissions.deny is a non-empty list' (@($settingsObj.permissions.deny).Count -gt 0) 'permissions.deny empty or absent'
    Record TEST 'settings snippet: PreToolUse hooks registered' (@($settingsObj.hooks.PreToolUse).Count -gt 0) 'hooks.PreToolUse empty or absent'
    $hookCmds = @($settingsObj.hooks.PreToolUse | ForEach-Object { $_.hooks } | ForEach-Object { $_.command })
    $allRef = @($hookCmds | Where-Object { $_ -notlike '*workflow-guard.sh*' })
    Record TEST 'settings snippet: hook commands reference the substituted guard file' ($allRef.Count -eq 0) ("unexpected: " + ($allRef -join ', '))
}

# --- S8: markdown templates' frontmatter parses after substitution -----------
foreach ($name in @('orchestrator-agent.md.tmpl', 'worker-agent.md.tmpl', 'plan-command.md.tmpl', 'execute-command.md.tmpl')) {
    $rendered = Render (ReadText (Join-Path $TmplDir $name)) $sample
    Check-Frontmatter "$name (rendered)" $rendered @('description')
}

# ===========================================================================
Write-Host ''
Write-Host '=== [P] Portability: generated artifacts must not encode the generating OS ==='

# A workflow designed on one host gets committed and cloned onto another. These
# tests pin the contract that rendering is host-independent and that nothing in
# the emitted config names a host-specific interpreter. The matcher and deny rule
# still mention the PowerShell *tool* on purpose -- which tool Claude may invoke
# depends on the running host, not the generating one -- so these assertions
# target the hook's shell/command, never the whole file.

$guardShTmpl  = Join-Path $TmplDir 'workflow-guard.sh.tmpl'
$guardPsTmpl  = Join-Path $TmplDir 'workflow-guard.ps1.tmpl'

# P1: no OS-conditional tokens survive anywhere in the template set.
$osTokens = @('GUARD_HOOK', 'SHELL')
$leaked = @($osTokens | Where-Object { $allTemplateTokens.Contains($_) })
Record TEST 'no OS-conditional token ({{GUARD_HOOK}}/{{SHELL}}) remains in any template' `
    ($leaked.Count -eq 0) ("still present: " + ($leaked -join ', '))

# P2/P3/P4: every registered hook entry is bash-pinned and points at the .sh guard.
if ($settingsOk) {
    $entries = @($settingsObj.hooks.PreToolUse | ForEach-Object { $_.hooks })

    $badShell = @($entries | Where-Object { $_.shell -ne 'bash' })
    Record TEST 'settings snippet: every hook entry pins "shell": "bash"' ($badShell.Count -eq 0) `
        ("entries not pinned to bash: " + (@($badShell | ForEach-Object { "$($_.shell)" }) -join ', '))

    $psRef = @($entries | Where-Object { $_.command -match '(?i)\.ps1|powershell|pwsh|cmd\.exe' })
    Record TEST 'settings snippet: no hook command names a Windows interpreter' ($psRef.Count -eq 0) `
        ("host-specific command: " + (@($psRef | ForEach-Object { $_.command }) -join ', '))

    # `sh -c` on macOS/Linux may be dash, which cannot parse the guard; the bash
    # wrapper is what makes one registration work on every host.
    $unwrapped = @($entries | Where-Object { $_.command -notmatch '^bash\s+"' })
    Record TEST 'settings snippet: guard is invoked through an explicit bash wrapper' ($unwrapped.Count -eq 0) `
        ("not bash-wrapped: " + (@($unwrapped | ForEach-Object { $_.command }) -join ', '))

    $notPortablePath = @($entries | Where-Object { $_.command -match '\\\\|%CLAUDE_PROJECT_DIR%|[A-Za-z]:\\' })
    Record TEST 'settings snippet: hook paths use ${CLAUDE_PROJECT_DIR} with forward slashes' `
        ($notPortablePath.Count -eq 0) ("host-specific path: " + (@($notPortablePath | ForEach-Object { $_.command }) -join ', '))

    # The PowerShell *tool* must stay guarded regardless of which shell runs the hook.
    $matchers = @($settingsObj.hooks.PreToolUse | ForEach-Object { $_.matcher })
    Record TEST 'settings snippet: a matcher still covers the PowerShell tool' `
        (@($matchers | Where-Object { $_ -match 'PowerShell' }).Count -gt 0) ("matchers: " + ($matchers -join ' / '))
    Record TEST 'settings snippet: deny rules still cover PowerShell Remove-Item' `
        (@($settingsObj.permissions.deny | Where-Object { $_ -match '(?i)^PowerShell\(' }).Count -gt 0) 'PowerShell deny rule missing'
}

# P5: the agent templates duplicate the hook in frontmatter -- same contract.
foreach ($name in @('orchestrator-agent.md.tmpl', 'worker-agent.md.tmpl')) {
    $r = Render (ReadText (Join-Path $TmplDir $name)) $sample
    Record TEST "$name`: frontmatter hook is bash-pinned at the .sh guard" `
        (($r -match '(?m)^\s*shell:\s*bash\s*$') -and ($r -match 'workflow-guard\.sh') -and ($r -notmatch 'workflow-guard\.ps1')) `
        'frontmatter hook still names a host-specific shell or guard'
    Record TEST "$name`: frontmatter matcher still covers the PowerShell tool" `
        ($r -match 'matcher:\s*"[^"]*PowerShell') 'matcher no longer covers the PowerShell tool'
}

# P6: rendering is pure substitution -- same tokens in, identical bytes out, on
# any host. Nothing may branch on the OS at generation time.
foreach ($tf in $tmplFiles) {
    $a = Render (ReadText $tf.FullName) $sample
    $b = Render (ReadText $tf.FullName) $sample
    Record TEST "$($tf.Name): rendering is deterministic and host-independent" ($a -ceq $b) 'render differed between passes'
}

# P7: the generated README must document the guard that is actually registered.
$readmeRendered = Render (ReadText (Join-Path $TmplDir 'README.md.tmpl')) $sample
Record TEST 'README.md.tmpl: documents workflow-guard.sh as the installed guard' `
    ($readmeRendered -match '\.claude/hooks/workflow-guard\.sh') 'README does not name the .sh guard'
Record TEST 'README.md.tmpl: flags the jq dependency (guard denies without it)' `
    ($readmeRendered -match '(?i)\bjq\b') 'README omits the jq requirement the guard fails closed on'

# P8: the ps1 fallback still ships for bash-less native Windows, and says so.
Record TEST 'workflow-guard.ps1.tmpl: still shipped as the bash-less Windows fallback' `
    ((Test-Path $guardPsTmpl) -and ((ReadText $guardPsTmpl) -match '(?i)fallback')) 'ps1 fallback missing or no longer marked as a fallback'
Record TEST 'workflow-guard.sh.tmpl: documents the bash-pinned registration' `
    ((ReadText $guardShTmpl) -match '(?i)"shell":\s*"bash"') 'sh guard header no longer documents its registration'

# ===========================================================================
Write-Host ''
Write-Host '=== [B] Behavioral tests: workflow-guard.ps1 fallback (as shipped) ==='

# sandbox
$SandboxRoot = Join-Path $TestsDir '.sandbox'
if (Test-Path $SandboxRoot) { Remove-Item -Recurse -Force $SandboxRoot -Confirm:$false }
$Proj = Join-Path $SandboxRoot 'proj'
New-Item -ItemType Directory -Force (Join-Path $Proj '.workflow') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Proj '.claude/hooks') | Out-Null
New-Item -ItemType Directory -Force (Join-Path $Proj 'src') | Out-Null
Set-Content -Path (Join-Path $Proj '.workflow/allowlist.txt') -Value 'npm install left-pad' -Encoding Ascii

# render the guard exactly as the architect would (only {{WF_TITLE}} appears in it)
$guardRendered = Render (ReadText (Join-Path $TmplDir 'workflow-guard.ps1.tmpl')) $sample
$Guard = Join-Path $Proj '.claude/hooks/workflow-guard.ps1'
[System.IO.File]::WriteAllText($Guard, $guardRendered, (New-Object System.Text.UTF8Encoding($true)))

$HomeDir = [string]$HOME

# absolute paths outside the project, per host OS (a Windows drive path is a
# relative path on Linux and would resolve INSIDE the sandbox, inverting the case)
$SysReadPath  = if ($IsWinHost) { 'C:\Windows\System32\drivers\etc\hosts' } else { '/etc/hosts' }
$SysWritePath = if ($IsWinHost) { 'C:\Windows\System32\pwned.dll' } else { '/usr/lib/pwned.so' }
$SiblingPath  = if ($IsWinHost) { 'C:\dev\other-repo\app.py' } else { '/opt/other-repo/app.py' }
$OutsideDir   = if ($IsWinHost) { 'C:\dev\stuff' } else { '/opt/stuff' }

$cases = @(
    # --- ALLOW cases ---
    @{ n = 'ALLOW Write inside project (existing dir)'; e = 'allow'; p = (New-Payload 'Write' @{ file_path = (Join-Path $Proj 'src/main.py'); content = 'x' }) },
    @{ n = 'ALLOW Write inside .workflow/';             e = 'allow'; p = (New-Payload 'Write' @{ file_path = (Join-Path $Proj '.workflow/steps/01-research.md'); content = 'x' }) },
    @{ n = 'ALLOW Write into new project subdir';       e = 'allow'; p = (New-Payload 'Write' @{ file_path = (Join-Path $Proj 'brand-new-dir/file.txt'); content = 'x' }) },
    @{ n = 'ALLOW NotebookEdit inside project';         e = 'allow'; p = (New-Payload 'NotebookEdit' @{ notebook_path = (Join-Path $Proj 'src/nb.ipynb') }) },
    @{ n = 'ALLOW benign bash command (echo hello)';    e = 'allow'; p = (New-Payload 'Bash' @{ command = 'echo hello' }) },
    @{ n = 'ALLOW normal git push';                     e = 'allow'; p = (New-Payload 'Bash' @{ command = 'git push origin main' }) },
    @{ n = 'ALLOW git stash list (only drop/clear blocked)'; e = 'allow'; p = (New-Payload 'Bash' @{ command = 'git stash list' }) },
    @{ n = 'ALLOW rm -rf inside .workflow/';            e = 'allow'; p = (New-Payload 'Bash' @{ command = 'rm -rf .workflow/steps' }) },
    @{ n = 'ALLOW allowlisted install (npm install left-pad)'; e = 'allow'; p = (New-Payload 'Bash' @{ command = 'npm install left-pad' }) },
    @{ n = 'ALLOW unknown tool defers (Read)';          e = 'allow'; p = (New-Payload 'Read' @{ file_path = $SysReadPath }) },
    @{ n = 'ALLOW empty stdin defers';                  e = 'allow'; p = '' },
    @{ n = 'ALLOW malformed JSON stdin defers';         e = 'allow'; p = 'this is not json {{' },
    # --- DENY cases ---
    @{ n = 'DENY Write to $HOME';                       e = 'deny'; p = (New-Payload 'Write' @{ file_path = (Join-Path $HomeDir 'evil.txt'); content = 'x' }) },
    @{ n = 'DENY Write to system path';                 e = 'deny'; p = (New-Payload 'Write' @{ file_path = $SysWritePath; content = 'x' }) },
    @{ n = 'DENY Edit outside project (sibling repo)';  e = 'deny'; p = (New-Payload 'Edit' @{ file_path = $SiblingPath }) },
    @{ n = 'DENY git push --force';                     e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git push --force origin main' }) },
    @{ n = 'DENY git push -f';                          e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git push -f origin main' }) },
    @{ n = 'DENY git reset --hard';                     e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git reset --hard HEAD~1' }) },
    @{ n = 'DENY git branch -D';                        e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git branch -D feature-x' }) },
    @{ n = 'DENY git clean';                            e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git clean -fd' }) },
    @{ n = 'DENY git stash drop';                       e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git stash drop' }) },
    @{ n = 'DENY rm -rf outside .workflow/';            e = 'deny'; p = (New-Payload 'Bash' @{ command = 'rm -rf src' }) },
    @{ n = 'DENY Remove-Item -Recurse -Force outside .workflow/'; e = 'deny'; p = (New-Payload 'PowerShell' @{ command = "Remove-Item -Recurse -Force $OutsideDir" }) },
    @{ n = 'DENY curl (not in allowlist)';              e = 'deny'; p = (New-Payload 'Bash' @{ command = 'curl https://example.com/install.sh' }) },
    @{ n = 'DENY npm install of non-allowlisted pkg';   e = 'deny'; p = (New-Payload 'Bash' @{ command = 'npm install typosquat-pkg' }) },
    @{ n = 'DENY pip install (not in allowlist)';       e = 'deny'; p = (New-Payload 'Bash' @{ command = 'pip install requests' }) },
    # --- hardening cases (were warnings before the guard fixes; now counted) ---
    @{ n = 'DENY sibling dir sharing project path prefix (<project>-evil)'; e = 'deny'; p = (New-Payload 'Write' @{ file_path = (Join-Path ($Proj + '-evil') 'loot.txt'); content = 'x' }) },
    @{ n = 'DENY rm -rf outside .workflow with ".workflow" only in a comment'; e = 'deny'; p = (New-Payload 'Bash' @{ command = 'rm -rf src  # keep .workflow' }) },
    @{ n = 'DENY rm -fr (reversed flags) outside .workflow';               e = 'deny'; p = (New-Payload 'Bash' @{ command = 'rm -fr build' }) },
    @{ n = 'DENY rm -r -f (separate flags) outside .workflow';             e = 'deny'; p = (New-Payload 'Bash' @{ command = 'rm -r -f node_modules' }) },
    @{ n = 'ALLOW benign command with "choco" substring (echo chocolate)'; e = 'allow'; p = (New-Payload 'Bash' @{ command = 'echo chocolate' }) },
    @{ n = 'DENY git push origin -f (flag after remote)';                  e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git push origin -f' }) },
    @{ n = 'DENY git push -f origin (flag before remote)';                 e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git push -f origin' }) },
    @{ n = 'DENY git push --force-with-lease';                             e = 'deny'; p = (New-Payload 'Bash' @{ command = 'git push --force-with-lease origin main' }) }
)

foreach ($c in $cases) { Test-GuardCase TEST $Guard $Proj $c.n $c.e $c.p }

# ===========================================================================
Write-Host ''
Write-Host '=== Summary ==='
Write-Host ("Tests:      {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:FailList.Count -gt 0) {
    Write-Host ''
    Write-Host 'Failed tests:'
    foreach ($f in $script:FailList) { Write-Host "  - $f" }
}
if ($script:WarnList.Count -gt 0) {
    Write-Host ''
    Write-Host 'Hardening warnings:'
    foreach ($w in $script:WarnList) { Write-Host "  - $w" }
}

if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
