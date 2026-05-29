#!/usr/bin/env bash
# Backup Claude Code's local state to a destination directory.
# Mirrors ~/.claude/ (transcripts, settings, auxiliary state) and also copies
# ~/.claude.json (which lives outside ~/.claude/ and is missed by the obvious
# rsync ~/.claude/ approach).
#
# Usage:
#   ./backup.sh [dest_dir]
#
# If dest_dir is omitted, defaults to ~/ClaudeCodeBackups.
# Re-runs are incremental (rsync). Safe to alias and run on a schedule.
set -e

DEST="${1:-$HOME/ClaudeCodeBackups}"
mkdir -p "$DEST"

echo "Backing up Claude Code state to: $DEST"
echo ""

# Mirror ~/.claude/ — projects (transcripts), todos, shell-snapshots, file-history,
# paste-cache, image-cache, session-env, settings.json. Exclude debug/ and statsig/
# which churn constantly and aren't needed for resume.
rsync -av --exclude='debug' --exclude='statsig' \
  "$HOME/.claude/" "$DEST/"

# ~/.claude.json lives in $HOME, not ~/.claude/, so a naive rsync of ~/.claude/
# misses it. It holds: Anthropic auth state, MCP server registry, recent-projects
# list, per-project trust state. Losing it on migration = re-add every MCP server
# and re-accept every project trust dialog.
if [[ -f "$HOME/.claude.json" ]]; then
  cp "$HOME/.claude.json" "$DEST/.claude.json.snapshot"
  echo ""
  echo "Captured ~/.claude.json -> $DEST/.claude.json.snapshot"
fi

# Quick summary
echo ""
echo "Backup complete."
primary=$(find "$DEST/projects" -maxdepth 2 -name '*.jsonl' -type f 2>/dev/null \
  | grep -v '/subagents/' | wc -l | xargs)
echo "Primary sessions in backup: $primary"
