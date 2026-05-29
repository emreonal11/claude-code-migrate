#!/usr/bin/env bash
# Restore Claude Code state from a backup directory onto this machine.
# Handles same-username (straight rsync) and different-username (path-rewrite)
# migrations. Idempotent — re-runs merge, never delete.
#
# Usage:
#   ./restore.sh <backup_dir>
#
# Where <backup_dir> is the destination passed to backup.sh on the old machine
# (e.g. ~/ClaudeCodeBackups). Must contain a projects/ subdir.
#
# The script warns if cleanupPeriodDays isn't set in ~/.claude/settings.json
# (default-30 prunes restored sessions on next Claude launch). Set it before
# running for a clean run, or respond to the warning prompt.
set -e

if [[ -z "$1" ]]; then
  echo "Usage: $0 <backup_dir>"
  echo "Example: $0 ~/ClaudeCodeBackups"
  exit 1
fi

# Allow ~ in input
BACKUP="${1/#\~/$HOME}"
BACKUP="$(cd "$BACKUP" && pwd)"

if [[ ! -d "$BACKUP/projects" ]]; then
  echo "ERROR: $BACKUP/projects not found — is this a backup directory?"
  exit 1
fi

# --- Detect username mismatch from slug encoding -----------------------------
# Project slugs encode the absolute cwd: /Users/alice/foo -> -Users-alice-foo.
# If the backup was made by 'alice' and we're 'bob' now, slugs need renaming
# AND path strings inside each .jsonl need rewriting.
SAMPLE_SLUG=$(ls "$BACKUP/projects" | grep '^-Users-' | head -1)
if [[ -z "$SAMPLE_SLUG" ]]; then
  echo "ERROR: no -Users-* project slugs in $BACKUP/projects."
  exit 1
fi
SOURCE_USER=$(echo "$SAMPLE_SLUG" | sed 's|^-Users-\([^-]*\)-.*|\1|')
TARGET_USER="$(whoami)"

SESSION_COUNT=$(find "$BACKUP/projects" -name '*.jsonl' -type f | wc -l | xargs)

echo "=== Claude Code Restore ==="
echo "Backup:          $BACKUP"
echo "Source username: $SOURCE_USER"
echo "This username:   $TARGET_USER"
echo "Sessions:        $SESSION_COUNT (including subagent transcripts)"
echo ""

# Warn if cleanupPeriodDays isn't set high — the default-30 will re-prune.
# Three cases to handle: file missing entirely (fresh Claude install), file
# exists but key missing, file exists with key set.
SETTINGS="$HOME/.claude/settings.json"
CURRENT_RETENTION="missing"
if [[ -f "$SETTINGS" ]]; then
  CURRENT_RETENTION=$(jq -r '.cleanupPeriodDays // "null"' "$SETTINGS" 2>/dev/null || echo "unknown")
fi
if [[ "$CURRENT_RETENTION" == "null" || "$CURRENT_RETENTION" == "unknown" || "$CURRENT_RETENTION" == "missing" ]]; then
  echo "WARNING: cleanupPeriodDays is not set in ~/.claude/settings.json — Claude"
  echo "will prune restored sessions older than 30 days on next launch."
  echo ""
  echo "Set it now (recommended):"
  echo "  mkdir -p ~/.claude"
  echo "  [[ -f $SETTINGS ]] || echo '{}' > $SETTINGS"
  echo "  jq '. + {cleanupPeriodDays: 999999}' $SETTINGS > $SETTINGS.tmp && mv $SETTINGS.tmp $SETTINGS"
  echo ""
  read -p "Continue anyway? (y/n) " -n 1 -r; echo ""
  [[ $REPLY =~ ^[Yy]$ ]] || exit 0
fi

read -p "Proceed with restore? (y/n) " -n 1 -r; echo ""
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

mkdir -p "$HOME/.claude/projects"

# --- Same-username path: straight rsync, no rewriting needed -----------------
if [[ "$SOURCE_USER" == "$TARGET_USER" ]]; then
  echo ""
  echo "Same username — direct rsync."
  rsync -av --exclude='.DS_Store' "$BACKUP/projects/" "$HOME/.claude/projects/"

  for sub in todos tasks shell-snapshots file-history paste-cache image-cache session-env; do
    if [[ -d "$BACKUP/$sub" ]]; then
      echo ""
      echo "Restoring $sub/ ..."
      rsync -av --exclude='.DS_Store' "$BACKUP/$sub/" "$HOME/.claude/$sub/"
    fi
  done

# --- Different-username path: rename slug dirs + sed-rewrite path strings ----
else
  echo ""
  echo "Username differs — rewriting /Users/$SOURCE_USER -> /Users/$TARGET_USER"
  echo "across slug directory names AND inside every .jsonl file."
  read -p "Confirm path rewrite? (y/n) " -n 1 -r; echo ""
  [[ $REPLY =~ ^[Yy]$ ]] || exit 0

  cd "$BACKUP/projects"
  COPIED=0
  for slug in -Users-"$SOURCE_USER"-*; do
    [[ -d "$slug" ]] || continue
    new_slug=$(echo "$slug" | sed "s|^-Users-$SOURCE_USER-|-Users-$TARGET_USER-|")
    target="$HOME/.claude/projects/$new_slug"
    mkdir -p "$target"
    while IFS= read -r f; do
      rel="${f#$slug/}"
      dst="$target/$rel"
      mkdir -p "$(dirname "$dst")"
      if [[ "$f" == *.jsonl ]]; then
        sed "s|/Users/$SOURCE_USER/|/Users/$TARGET_USER/|g" "$f" > "$dst"
        COPIED=$((COPIED+1))
      else
        cp "$f" "$dst"
      fi
    done < <(find "$slug" -type f ! -name '.DS_Store')
  done
  echo "Rewrote $COPIED .jsonl files."
  echo ""
  echo "Note: auxiliary dirs (todos/, shell-snapshots/, etc.) are skipped in the"
  echo "different-user path. Most sessions resume fine without them. Restore"
  echo "manually if needed: rsync -av $BACKUP/todos/ ~/.claude/todos/"
fi

# --- Restore ~/.claude.json snapshot (auth/MCP/trust state) ------------------
if [[ -f "$BACKUP/.claude.json.snapshot" ]]; then
  echo ""
  echo "Found .claude.json.snapshot."
  echo "  Contains: MCP server registry, recent-projects list, per-project trust state."
  echo "  Note: Anthropic auth token is machine-bound — you'll still need 'claude --login'."
  if [[ -f "$HOME/.claude.json" ]]; then
    BACKUP_PATH="$HOME/.claude.json.before-restore-$(date +%s)"
    echo "  Current ~/.claude.json -> $BACKUP_PATH (safety backup)"
  fi
  read -p "Restore .claude.json? (y/n) " -n 1 -r; echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    [[ -f "$HOME/.claude.json" ]] && cp "$HOME/.claude.json" "$BACKUP_PATH"
    cp "$BACKUP/.claude.json.snapshot" "$HOME/.claude.json"
    echo "Restored ~/.claude.json"
  fi
fi

echo ""
echo "=== Done ==="
echo "Next: cd into a project directory and run 'claude --resume'."
echo "      Run 'claude --login' to re-establish Anthropic auth."
echo "      OAuth-based MCP servers may re-prompt for auth on first use."
