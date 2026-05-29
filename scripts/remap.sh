#!/usr/bin/env bash
# Rebind Claude Code session history from one path to another on the same
# machine. The script doesn't require either path to exist on disk — it
# operates purely on the path strings encoded in ~/.claude/ slug names,
# .jsonl cwd/path fields, and ~/.claude.json's projects map.
#
# Use when:
#   - You moved or renamed a directory and want `claude --resume` to find
#     your sessions at the new location
#   - You want to retarget session history to a different path pre-emptively
#     (before moving the code, or to a location that doesn't exist yet)
#   - The new path is unrelated to the old (any path -> any path)
#
# Usage:
#   ./remap.sh <old_path> <new_path>
#
# Example:
#   ./remap.sh /Users/alice/code /Users/alice/dev
#
# Sessions previously rooted under /Users/alice/code or /Users/alice/code/*
# get rebound to /Users/alice/dev or /Users/alice/dev/*. Slug directories
# are renamed in place, cwd/path fields inside .jsonl files are rewritten,
# and ~/.claude.json's projects map is updated.
#
# Refused: identical from/to paths; target slug already exists (manual
# merge required).
#
# Idempotent on the unchanged set: re-running with the same args after
# completion is a no-op (nothing matches OLD anymore).
set -e

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <old_path> <new_path>"
  echo "Example: $0 /Users/alice/code /Users/alice/dev"
  exit 1
fi

# Strip trailing slashes
OLD="${1%/}"
NEW="${2%/}"

if [[ "$OLD" == "$NEW" ]]; then
  echo "ERROR: old and new paths are identical."
  exit 1
fi

PROJECTS_DIR="$HOME/.claude/projects"
SETTINGS="$HOME/.claude.json"

if [[ ! -d "$PROJECTS_DIR" ]]; then
  echo "ERROR: $PROJECTS_DIR does not exist."
  exit 1
fi

# --- Find slugs whose ACTUAL cwd (inside jsonls) starts with OLD ------------
# Don't trust slug pattern-matching alone — the encoding is ambiguous: paths
# /Users/alice/code/foo and /Users/alice/code-foo both encode to
# -Users-alice-code-foo. We inspect the cwd field of the first jsonl in each
# slug dir and match on the real path.
MATCHES=()
for slug in "$PROJECTS_DIR"/*; do
  [[ -d "$slug" ]] || continue
  jsonl=$(find "$slug" -name '*.jsonl' -type f 2>/dev/null | head -1)
  [[ -n "$jsonl" ]] || continue
  cwd=$(grep -o '"cwd":"[^"]*"' "$jsonl" 2>/dev/null | head -1 | sed 's|"cwd":"||; s|"$||')
  if [[ "$cwd" == "$OLD" || "$cwd" == "$OLD/"* ]]; then
    MATCHES+=("$slug")
  fi
done

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  echo "No session directories have a cwd under $OLD."
  exit 0
fi

# --- Preview ----------------------------------------------------------------
echo "=== Path Remap ==="
echo "From: $OLD"
echo "To:   $NEW"
echo ""
echo "Will re-bind ${#MATCHES[@]} slug(s):"
for slug in "${MATCHES[@]}"; do
  jsonl=$(find "$slug" -name '*.jsonl' -type f 2>/dev/null | head -1)
  cwd=$(grep -o '"cwd":"[^"]*"' "$jsonl" | head -1 | sed 's|"cwd":"||; s|"$||')
  new_cwd="$NEW${cwd#$OLD}"
  new_slug_name=$(echo "$new_cwd" | sed 's|/|-|g')
  count=$(find "$slug" -name '*.jsonl' -type f | wc -l | xargs)
  printf "  %s\n     cwd: %s -> %s  (%s files)\n" \
    "$(basename "$slug")" "$cwd" "$new_cwd" "$count"
done
echo ""

# --- Conflict check: target slug must not already exist --------------------
for slug in "${MATCHES[@]}"; do
  jsonl=$(find "$slug" -name '*.jsonl' -type f 2>/dev/null | head -1)
  cwd=$(grep -o '"cwd":"[^"]*"' "$jsonl" | head -1 | sed 's|"cwd":"||; s|"$||')
  new_cwd="$NEW${cwd#$OLD}"
  new_slug_name=$(echo "$new_cwd" | sed 's|/|-|g')
  if [[ -d "$PROJECTS_DIR/$new_slug_name" ]]; then
    echo "ERROR: target slug already exists, would overwrite:"
    echo "  $PROJECTS_DIR/$new_slug_name"
    echo "Move or merge the existing one manually before re-running."
    exit 1
  fi
done

read -p "Proceed? (y/n) " -n 1 -r; echo ""
[[ $REPLY =~ ^[Yy]$ ]] || exit 0

# --- Apply: rename slug dirs + rewrite .jsonl path strings -----------------
COUNT=0
for slug in "${MATCHES[@]}"; do
  jsonl=$(find "$slug" -name '*.jsonl' -type f 2>/dev/null | head -1)
  cwd=$(grep -o '"cwd":"[^"]*"' "$jsonl" | head -1 | sed 's|"cwd":"||; s|"$||')
  new_cwd="$NEW${cwd#$OLD}"
  new_slug_name=$(echo "$new_cwd" | sed 's|/|-|g')
  mv "$slug" "$PROJECTS_DIR/$new_slug_name"

  # Rewrite path strings inside every .jsonl. Two patterns:
  #   1) "$OLD/..." -> "$NEW/..." — covers any path component continuation
  #      (cwd:"/x/y", file_path:"/x/y/z", embedded "cat /x/y/foo", etc.)
  #   2) "$OLD" (exact, quoted) -> "$NEW" — covers the cwd field when the
  #      remapped path is exactly OLD with no trailing component
  while IFS= read -r f; do
    sed "s|$OLD/|$NEW/|g; s|\"$OLD\"|\"$NEW\"|g" "$f" > "$f.new" && mv "$f.new" "$f"
  done < <(find "$PROJECTS_DIR/$new_slug_name" -name '*.jsonl' -type f)
  COUNT=$((COUNT+1))
done

echo "Renamed $COUNT slug dir(s)."

# --- Update ~/.claude.json projects map ------------------------------------
# Projects map is keyed by absolute path; same prefix rewrite logic.
if [[ -f "$SETTINGS" ]]; then
  if command -v jq >/dev/null; then
    cp "$SETTINGS" "$SETTINGS.before-remap-$(date +%s)"
    jq --arg from "$OLD" --arg to "$NEW" '
      if .projects then
        .projects |= with_entries(
          .key |= (
            if . == $from then $to
            elif startswith($from + "/") then $to + .[($from | length):]
            else . end
          )
        )
      else . end
    ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
    echo "Updated ~/.claude.json projects map (safety backup: $SETTINGS.before-remap-*)."
  else
    echo "WARNING: jq not found — skipped updating ~/.claude.json. Per-project trust"
    echo "and config state will not follow to the new path until you reinstall jq and re-run,"
    echo "edit the file manually, or re-trust each project on first use."
  fi
fi

echo ""
echo "Done. cd $NEW (or a subdirectory) and run 'claude --resume' to verify."
