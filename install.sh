#!/usr/bin/env bash
# install.sh -- installs the workflow-architect system into the user-level
# Claude Code config. POSIX peer of install.ps1.
#
# Copies the agent, slash command, and skill pack from this repo into ~/.claude,
# which is what makes them available from any directory in any session. Existing
# files are backed up alongside the target with a .bak extension before being
# overwritten.
#
# Usage: install.sh [--claude-home <dir>] [--dry-run]
#   --claude-home <dir>   Target config root. Defaults to ~/.claude.
#   --dry-run             Show what would be copied without writing anything.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_HOME="$HOME/.claude"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --claude-home) CLAUDE_HOME="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=1; shift ;;
    *) echo "Unknown option: $1" >&2
       echo "Usage: install.sh [--claude-home <dir>] [--dry-run]" >&2
       exit 2 ;;
  esac
done

for item in \
  agents/workflow-architect.md \
  commands/design-workflow.md \
  skills/workflow-design
do
  src="$REPO/$item"
  dst="$CLAUDE_HOME/$item"

  if [ ! -e "$src" ]; then echo "Missing source: $src" >&2; exit 1; fi

  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -e "$dst" ]; then echo "  would back up $dst to $dst.bak"; fi
    echo "  would install $item"
    continue
  fi

  mkdir -p "$(dirname "$dst")"

  if [ -e "$dst" ]; then
    rm -rf "$dst.bak"
    mv "$dst" "$dst.bak"
  fi

  cp -R "$src" "$dst"
  echo "  installed $item"
done

echo ''
if [ "$DRY_RUN" -eq 1 ]; then
  echo "Dry run: nothing written (target: $CLAUDE_HOME)"
else
  echo "Installed to $CLAUDE_HOME"
  echo 'Start a new Claude Code session and run /design-workflow to use it.'
fi
