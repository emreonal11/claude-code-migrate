# claude-code-migrate

Migrate [Claude Code](https://docs.anthropic.com/en/docs/claude-code) state between machines, or rebind a project's session history to a different path on the same machine. Preserves sessions, settings, and MCP server registry across the move; avoids the default 30-day cleanup.

Anthropic doesn't ship native session export ([issue #18645](https://github.com/anthropics/claude-code/issues/18645)).

**Tested on:** macOS Tahoe, Claude Code v2.1.x. Mac-to-Mac migration and same-machine path remap both verified end-to-end. Linux is not tested: `backup.sh`, `remap.sh`, and the same-username path of `restore.sh` are filesystem-prefix-agnostic and likely work. The different-username path of `restore.sh` hardcodes `/Users/` and won't work on Linux without edits.

---

## TL;DR

```bash
# OLD MACHINE — set up an alias, then run the backup
echo "alias claude-backup='rsync -av --exclude=debug --exclude=statsig ~/.claude/ ~/ClaudeCodeBackups/ && cp ~/.claude.json ~/ClaudeCodeBackups/.claude.json.snapshot 2>/dev/null'" >> ~/.zshrc
source ~/.zshrc
claude-backup

# Transfer ~/ClaudeCodeBackups/ to the new machine. The folder has thousands of
# small files — zip first, transfer the zip, unzip on the other side. Much faster.
#   cd ~ && zip -rqy ccb.zip ClaudeCodeBackups   # then AirDrop / scp / external drive

# NEW MACHINE — disable cleanup FIRST, then restore
mkdir -p ~/.claude
[[ -f ~/.claude/settings.json ]] || echo '{}' > ~/.claude/settings.json
jq '. + {cleanupPeriodDays: 999999}' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json

rsync -av ~/ClaudeCodeBackups/projects/ ~/.claude/projects/
for sub in todos tasks shell-snapshots file-history paste-cache image-cache session-env; do
  rsync -av ~/ClaudeCodeBackups/$sub/ ~/.claude/$sub/ 2>/dev/null
done
cp ~/ClaudeCodeBackups/.claude.json.snapshot ~/.claude.json

# Clone your code repos at the same paths as the old machine, then:
cd <some-project-with-history>
claude --login
claude --resume
```

That's the entire migration. Read on for the mental model, the cleanup behavior, and the different-username path.

---

## The mental model

Three independent pieces have to move between machines. None of them touch each other on disk; the only link is `cwd` strings embedded in transcripts.

| What | Where | How it moves |
|---|---|---|
| **Code** | wherever you keep it (`~/projects/`, `~/work/`, etc.) | `git clone` for repos; you handle non-git dirs |
| **Session transcripts + auxiliary state** | `~/.claude/` | `rsync` (this repo) |
| **Global config: auth, MCP servers, trust state** | `~/.claude.json` (in `$HOME`, NOT `~/.claude/`) | `cp` (easy to miss) |

**Why path-matching matters.** Each session transcript lives at `~/.claude/projects/<slug>/<uuid>.jsonl`, where `<slug>` is the absolute cwd with `/` replaced by `-`. Example: `/Users/alice/projects/foo` → `-Users-alice-projects-foo`. When you run `claude --resume`, Claude reads transcripts from the slug matching your current `pwd`. If your code lives at the same absolute path on the new machine, resume finds the sessions automatically. If the username or paths changed, slugs and embedded path strings need rewriting.

---

## What transfers vs what doesn't

| Survives migration | Doesn't survive |
|---|---|
| Session transcripts (`*.jsonl`) | Anthropic auth token (machine-bound — run `claude --login`) |
| Sub-agent transcripts (`<uuid>/subagents/*.jsonl`) | MCP OAuth tokens (re-auth on first use of that server) |
| Per-project settings, allowed tools, trust state | `claude --continue` history pointer to current/most-recent session |
| MCP server configs (commands, URLs, env, API keys) | Plugins that depend on system binaries you haven't installed on the new machine |
| `settings.json` (with the `cleanupPeriodDays` fix below) | |
| `todos/`, `shell-snapshots/`, `file-history/`, `paste-cache/`, `image-cache/`, `session-env/` | |
| Recent-projects list (`~/.claude.json`'s `projects` map) | |

**MCP OAuth caveat.** Server *configs* restore via `~/.claude.json` — you won't have to `claude mcp add` everything again. OAuth-based servers may re-prompt for auth on first use; API-key-based servers typically don't. See [#52565](https://github.com/anthropics/claude-code/issues/52565) and [#58607](https://github.com/anthropics/claude-code/issues/58607) for context on OAuth persistence quirks.

---

## The 30-day cleanup

Claude Code prunes session transcripts older than **30 days** at startup. The age threshold is controlled by `cleanupPeriodDays` in `~/.claude/settings.json` (default: 30 if absent). Files are hard-deleted; no in-app recovery.

**Implication for migration:** if you restore a backup containing month-old sessions and then launch Claude before fixing the setting, it deletes them immediately. Order matters.

**Fix on every machine you want sessions to persist on:**

```bash
mkdir -p ~/.claude
[[ -f ~/.claude/settings.json ]] || echo '{}' > ~/.claude/settings.json
jq '. + {cleanupPeriodDays: 999999}' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json
jq '.cleanupPeriodDays' ~/.claude/settings.json     # confirms: 999999
```

(Any large positive integer works.)

**Set this BEFORE restoring transcripts on the new machine.**

**Also set it on the old machine.** Until you do, every Claude Code startup hard-deletes sessions older than 30 days. Backups capture only what's currently on disk, so a backup run today after months without the fix gives you a 30-day rolling window, not your full history. Setting `cleanupPeriodDays: 999999` on the old machine prevents further pruning; sessions from that point forward persist indefinitely. The ones already pruned are gone unless you have an external backup.

---

## Backup (on the machine with the sessions)

### Option A — alias (set once, run anytime)

```bash
echo "alias claude-backup='rsync -av --exclude=debug --exclude=statsig ~/.claude/ ~/ClaudeCodeBackups/ && cp ~/.claude.json ~/ClaudeCodeBackups/.claude.json.snapshot 2>/dev/null'" >> ~/.zshrc
source ~/.zshrc

claude-backup
```

Re-runs are incremental (`rsync`). Cheap to run on a schedule via cron.

### Option B — explicit commands

```bash
DEST=~/ClaudeCodeBackups
mkdir -p "$DEST"

# ~/.claude/ → DEST. Exclude debug/ and statsig/ (verbose logs + analytics cache,
# constantly changing, useless for resume).
rsync -av --exclude=debug --exclude=statsig ~/.claude/ "$DEST/"

# ~/.claude.json lives in $HOME, NOT ~/.claude/, so a naive mirror of ~/.claude/
# misses it. It holds your MCP server registry, recent-projects list, and per-project
# trust state — restoring it on the new machine avoids re-adding each MCP server
# and re-accepting each "trust this folder" prompt.
cp ~/.claude.json "$DEST/.claude.json.snapshot"
```

### Option C — `scripts/backup.sh` from this repo

```bash
./scripts/backup.sh ~/ClaudeCodeBackups
```

Does exactly what Option B does, plus prints a session count.

**Verify the backup is current:**

```bash
find ~/ClaudeCodeBackups/projects -maxdepth 2 -name '*.jsonl' -type f | grep -v '/subagents/' | wc -l
ls -la ~/ClaudeCodeBackups/.claude.json.snapshot
```

---

## Restore (on the new machine, same username)

Run `whoami`. If it matches the source machine, follow this section; otherwise see ["Restore (different username)"](#restore-different-username) below.

```bash
# 1. Disable the 30-day cleanup BEFORE anything else.
mkdir -p ~/.claude
[[ -f ~/.claude/settings.json ]] || echo '{}' > ~/.claude/settings.json
jq '. + {cleanupPeriodDays: 999999}' ~/.claude/settings.json > /tmp/s.json && mv /tmp/s.json ~/.claude/settings.json

# 2. Restore session transcripts.
rsync -av ~/ClaudeCodeBackups/projects/ ~/.claude/projects/

# 3. Restore auxiliary state (todos, shell snapshots, file history, etc.).
for sub in todos tasks shell-snapshots file-history paste-cache image-cache session-env; do
  [[ -d ~/ClaudeCodeBackups/$sub ]] && rsync -av ~/ClaudeCodeBackups/$sub/ ~/.claude/$sub/
done

# 4. Restore ~/.claude.json (back up the existing one first as a safety net).
[[ -f ~/.claude.json ]] && cp ~/.claude.json ~/.claude.json.before-restore-$(date +%s)
cp ~/ClaudeCodeBackups/.claude.json.snapshot ~/.claude.json

# 5. Clone your code repos at the SAME absolute paths as the old machine.
#    Example: if a slug is -Users-alice-projects-foo, the code must live at
#    /Users/alice/projects/foo on the new machine for resume to find it.
git clone <repo-url> ~/projects/foo
# (repeat for each repo with sessions)

# 6. Re-authenticate and try a resume.
cd ~/projects/foo
claude --login
claude --resume
```

### Or use `scripts/restore.sh`

```bash
./scripts/restore.sh ~/ClaudeCodeBackups
```

Interactive, asks before each destructive step, warns if `cleanupPeriodDays` isn't set, handles both same-user and different-user paths.

### Verify

```bash
# Session count should match old machine
find ~/.claude/projects -maxdepth 2 -name '*.jsonl' -type f | grep -v '/subagents/' | wc -l

# Cleanup config should be your chosen value
jq '.cleanupPeriodDays' ~/.claude/settings.json

# MCP servers should list what was on old machine
jq -r '.mcpServers | keys[]' ~/.claude.json

# Trust state should be present
jq -r '.projects | keys | length' ~/.claude.json
```

---

## Restore (different username)

The new machine's `whoami` doesn't match the old machine's. Both the slug directory names and the path strings inside each `*.jsonl` need rewriting.

The `restore.sh` script auto-detects this and handles it. If you'd rather do it manually:

```bash
SOURCE_USER=alice
TARGET_USER=$(whoami)
BACKUP=~/ClaudeCodeBackups
mkdir -p ~/.claude/projects

cd "$BACKUP/projects"
for slug in -Users-"$SOURCE_USER"-*; do
  [[ -d "$slug" ]] || continue
  new_slug=$(echo "$slug" | sed "s|^-Users-$SOURCE_USER-|-Users-$TARGET_USER-|")
  mkdir -p ~/.claude/projects/"$new_slug"
  find "$slug" -type f -name '*.jsonl' | while read f; do
    rel="${f#$slug/}"
    dst=~/.claude/projects/"$new_slug/$rel"
    mkdir -p "$(dirname "$dst")"
    # Global substring replace: /Users/<old>/ -> /Users/<new>/
    sed "s|/Users/$SOURCE_USER/|/Users/$TARGET_USER/|g" "$f" > "$dst"
  done
done
```

The `sed` covers the path fields in transcripts: `cwd`, `file_path`, `filePath`, `path`, and embedded paths in `command` strings. Auxiliary directories (`todos/`, `shell-snapshots/`, etc.) are skipped in this path; resume works without them in most cases.

`~/.claude.json`'s `projects` map is keyed by absolute path too — restore it with the same sed:

```bash
sed "s|/Users/$SOURCE_USER/|/Users/$TARGET_USER/|g" "$BACKUP/.claude.json.snapshot" > ~/.claude.json
```

---

## Rebind sessions to a different path (same machine)

If you've moved or renamed a project directory — or you want to retarget a project's session history to a different path on the same machine — use `scripts/remap.sh`. Both the slug directories under `~/.claude/projects/` and the path strings embedded inside the `.jsonl` transcripts (cwd, file_path, command args, etc.) get rewritten, and `~/.claude.json`'s projects map is updated to match.

```bash
./scripts/remap.sh <old_path> <new_path>

# Example: you moved your code from ~/code to ~/dev
./scripts/remap.sh /Users/alice/code /Users/alice/dev
```

Effect: every slug rooted under the old path is renamed to its new-path equivalent (`-Users-alice-code-foo` → `-Users-alice-dev-foo`), all embedded paths inside the `.jsonl` files (cwd, file_path, command strings) are rewritten, and `~/.claude.json`'s projects map keys are updated — preserving per-project trust state and config.

Constraints:
- Neither path needs to exist on disk — the script operates purely on the path strings encoded in `~/.claude/`. Useful for retargeting before/after the directory move.
- The new path's slug must not already exist (the script refuses with a clear error). If you want to merge two projects' histories, do that manually.
- Matching is by actual cwd inside each `.jsonl`, not by slug-name pattern — this disambiguates the encoding quirk where `/Users/alice/code/foo` and `/Users/alice/code-foo` produce the same slug `-Users-alice-code-foo`. The script only touches slugs whose real cwd is under the old path.

A safety backup of `~/.claude.json` is written to `~/.claude.json.before-remap-<timestamp>` before the projects map is rewritten.

Verify after running:
```bash
cd /Users/alice/dev          # or any subpath you remapped
claude --resume               # picker should show the rebound sessions
```

---

## FAQ

**I launched Claude on the new machine before disabling cleanup.** If the restore had already happened, transcripts older than 30 days are gone from `~/.claude/`. Recoverable from the backup directory — set `cleanupPeriodDays` first, then re-run the restore.

**Resume picker is empty / shows fewer sessions than expected.** The slug doesn't match your current `pwd`. Run `pwd` and compare to what's encoded in the slug name. Common cause: cloning a repo to a slightly different path (e.g. `~/code/foo` vs `~/projects/foo`). Fix: either move the code to the matching path, or run `scripts/remap.sh` to rebind the session history to the new path.

**A session shows up in the resume picker but errors with "no conversation found with session ID" when I open it.** The picker entry references a transcript file that isn't where Claude expects it — either the `.jsonl` wasn't restored, or the slug doesn't match the session's cwd. See [#41344](https://github.com/anthropics/claude-code/issues/41344).

**`claude --continue` doesn't pick up where I left off on the old machine.** The "current session" pointer doesn't survive migration. Use `claude --resume` and pick the session from the list.

**MCP server X isn't working.** `claude mcp list` should show it. If yes but functionality fails, it's likely an OAuth re-auth — trigger the server's auth flow or just use it once and respond to the prompt.

**Are the auxiliary directories required?** Helpful but not required.
- `todos/` — TaskCreate/TaskList state per session
- `shell-snapshots/` — `cd` history / shell env per session (improves Bash tool fidelity on resume)
- `file-history/` — Edit tool undo history
- `paste-cache/` / `image-cache/` — files pasted into chats and images shown in transcripts
- `session-env/` — misc per-session metadata

Skip them in low-disk situations; resume works without them.

**Is it safe to keep the backup folder in iCloud / Dropbox / Google Drive?** It contains your Anthropic auth token (in `.claude.json.snapshot`), API keys embedded in MCP configs (e.g. Exa), and every conversation transcript. Treat it as you would your shell history file: fine for personal cloud storage if you trust that provider with credentials, not fine for sharing. iCloud's many-small-files sync is also painfully slow — zip the backup before transferring.

**Copy fails with "Operation not permitted" on `~/Library` paths.** macOS sandboxing — run from Terminal directly rather than an IDE-integrated shell, or grant Full Disk Access to your terminal in System Settings → Privacy & Security.

---

## What this repo intentionally doesn't do

- **No cloud sync, no telemetry, no remote anything.** Local commands on local files only.
- **No "comprehensive backup product."** Scope is migration: enough state to move between machines and resume work. Not Git-history backup, not encrypted sync, not multi-machine continuous mirroring.
- **No session-format conversion.** Transcripts are stored as-is. Claude Code's jsonl schema changes occasionally; if a backup is years old and the schema has shifted, that's between you and Anthropic.
- **No auth-token rescue.** The Anthropic OAuth token is machine-bound by design. `claude --login` is the canonical path; this repo doesn't try to circumvent it.

---

## Credits & related

- [Issue #18645](https://github.com/anthropics/claude-code/issues/18645) — Anthropic's open feature request for native session export
- [Issue #41344](https://github.com/anthropics/claude-code/issues/41344) — directory-move-breaks-sessions bug
- [Issues #52565](https://github.com/anthropics/claude-code/issues/52565), [#58607](https://github.com/anthropics/claude-code/issues/58607) — MCP OAuth persistence quirks
- [code.claude.com session-storage docs](https://code.claude.com/docs/en/agent-sdk/session-storage) — semi-official reference for the on-disk layout (Agent SDK doc, but the layout is shared with the CLI)

PRs and bug reports welcome.

---

## License

MIT.
