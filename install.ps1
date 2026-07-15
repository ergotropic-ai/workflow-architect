<#
.SYNOPSIS
    Installs the workflow-architect system into the user-level Claude Code config.

.DESCRIPTION
    Copies the agent, slash command, and skill pack from this repo into ~/.claude,
    which is what makes them available from any directory in any session. Existing
    files are backed up alongside the target with a .bak extension before being
    overwritten.

.PARAMETER ClaudeHome
    Target config root. Defaults to ~/.claude.

.PARAMETER WhatIf
    Show what would be copied without writing anything.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ClaudeHome = (Join-Path $HOME '.claude')
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot

$items = @(
    @{ From = 'agents/workflow-architect.md';  To = 'agents/workflow-architect.md' }
    @{ From = 'commands/design-workflow.md';   To = 'commands/design-workflow.md' }
    @{ From = 'skills/workflow-design';        To = 'skills/workflow-design'; Dir = $true }
)

foreach ($item in $items) {
    $src = Join-Path $repo $item.From
    $dst = Join-Path $ClaudeHome $item.To

    if (-not (Test-Path $src)) { throw "Missing source: $src" }

    $parent = Split-Path $dst -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    if (Test-Path $dst) {
        $backup = "$dst.bak"
        if ($PSCmdlet.ShouldProcess($dst, "back up to $backup")) {
            if (Test-Path $backup) { Remove-Item $backup -Recurse -Force }
            Move-Item $dst $backup -Force
        }
    }

    if ($PSCmdlet.ShouldProcess($dst, "install from $src")) {
        Copy-Item $src $dst -Recurse -Force
        Write-Host "  installed $($item.To)"
    }
}

Write-Host ''
Write-Host "Installed to $ClaudeHome"
Write-Host 'Start a new Claude Code session and run /design-workflow to use it.'
