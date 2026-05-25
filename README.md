# Claude Git Hooks

Defensive git and claude hooks to protect against claude leaking emails into commits.

Global git hooks (`pre-commit`, `pre-push`) plus a Claude Code `SessionStart`
hook, packaged for one-paste install.

Stops two specific failure modes that bite anyone using Claude Code agents
across multiple repos:

1. **Real-email leaks into commit metadata.** Agents sometimes invent
   `git -c user.email=joe@me.com commit …` or `git commit --author=…`,
   sourcing the address from the `# userEmail` context that's in every
   session's system prompt. The override bypasses your `git config
   user.email` (the noreply alias). GitHub then blocks the push or — if
   the repo is public — your real address is permanently in the history.
2. **Claude's `EnterWorktree` tool silently writes `core.hooksPath` and
   `[worktree] baseRef` into the repo's local `.git/config`.** That local
   setting beats your `--global` `core.hooksPath`, so any global hooks
   you've installed quietly stop running for every repo Claude has ever
   touched. The write goes straight to the file — no `git config` command
   in transcripts to grep for.

This repo installs three small artifacts that, between them, close both holes
and stay invisible the rest of the time.

## What it installs

| Artifact | Installed at | Purpose |
|---|---|---|
| `hooks/pre-commit` | `~/.config/git/hooks/pre-commit` | Refuses any commit whose resolved author email differs from `git config user.email`. Catches `git -c user.email=…`, `--author=…`, and env-var overrides directly — zero config, just trusts your existing git identity. Optionally also scans staged ADDED lines for a banned regex (`hooks.bannedEmailsRegex`). Chains to per-repo `.git/hooks/pre-commit` if present. |
| `hooks/pre-push` | `~/.config/git/hooks/pre-push` | Name-gated email check. For each commit in the push range, if `author.name == git config user.name` then `author.email` MUST equal `git config user.email`. Catches leaks that bypassed pre-commit (other machines, cherry-picks, `--no-verify`); skips legitimate contributor commits (different `author.name`). Chains to per-repo `.git/hooks/pre-push`. |
| `heal-git-hooks.sh` | `~/.claude/heal-git-hooks.sh` | Claude Code `SessionStart` hook. On each session start, checks the project's `.git/config` and silently unsets `core.hooksPath` if it's self-referential (matches the repo's own default) or stale (target dir doesn't exist). Real per-repo hook systems (`.husky`, `.beads/hooks`, …) are left untouched. |

Plus one `git config --global` setting (`core.hooksPath`), one optional
setting (`hooks.bannedEmailsRegex`), and one `SessionStart` entry in
`~/.claude/settings.json`.

Both hooks **trust `git config user.email` (and `user.name`) as the source
of truth** — whatever email you've already configured for yourself is the
"allowed" identity. There's no separate allowlist regex to maintain. Set
your identity once with `git config --global user.email '<your-email>'`
(and `user.name`), and the hooks enforce it from then on, including
catching the exact `git -c user.email=…` override pattern that Claude
agents tend to invent from the `# userEmail` system context.

All scripts are stdlib bash — no Node, Python, or pre-commit-framework
dependency. Tested on macOS; should work on Linux with stock `git`/`awk`/`sed`.

## Install

Paste this prompt into a Claude Code session (any directory):

```markdown
Install the global git hooks from https://github.com/simple10/claude-git-hooks. Specifically:

1. Clone the repo to ~/.config/claude-git-hooks (or `git pull` if it's already there).
2. Verify my git identity is set: run `git config --global --get user.name` and `git config --global --get user.email`. If either is empty, stop and ask me — the hooks refuse to run without a configured identity. (If I'm using a GitHub noreply alias, that's <id>+<username>@users.noreply.github.com; otherwise whatever email I want every commit to use.)
3. Symlink (don't copy — symlinks let `git pull` in the repo dir update the installed hooks automatically):
   - ~/.config/claude-git-hooks/hooks/pre-commit → ~/.config/git/hooks/pre-commit
   - ~/.config/claude-git-hooks/hooks/pre-push   → ~/.config/git/hooks/pre-push
   - ~/.config/claude-git-hooks/heal-git-hooks.sh → ~/.claude/heal-git-hooks.sh
4. Set `git config --global core.hooksPath ~/.config/git/hooks`.
5. Ask me whether I want to set `hooks.bannedEmailsRegex` (optional content-scan that refuses commits whose staged ADDED lines contain a given regex — useful for catching personal/work email addresses, internal hostnames, etc. ending up in code). If yes, ask for the regex and set it with `git config --global hooks.bannedEmailsRegex '<regex>'`. Default: leave unset (no content scan).
6. Add a SessionStart hook to ~/.claude/settings.json under `hooks.SessionStart` that runs `bash ~/.claude/heal-git-hooks.sh` with `timeout: 5`. MERGE with the existing `hooks` block if any — don't replace.
7. Verify the install end-to-end:
   - Confirm `git config --global --get core.hooksPath` prints the hooks dir.
   - Confirm ~/.config/git/hooks/pre-commit and pre-push are executable.
   - Confirm `git var GIT_AUTHOR_IDENT` resolves to my configured <name> <email> (no env-var override leaking in from somewhere).
   - Pipe-test pre-push against HEAD of the current repo (synthesize the stdin git sends and run the hook directly) — should exit 0.
```

That's the whole install. The prompt is intentionally explicit so Claude
doesn't need to guess — every step has acceptance criteria. Re-pasting the
same prompt later is safe (idempotent: `ln -sf` overwrites, `git config
--global` reassigns, the SessionStart merge is a no-op if it already
exists).

## Configure

The hooks read three `git config` keys. The first two are git's own
standard identity keys — you've almost certainly set them already. The
third is an optional content-scan toggle. All three can be set globally
or overridden per-repo with `git config --local`.

| Key | Default | What it does |
|---|---|---|
| `user.email` | (set by you) | The hooks' source of truth for "your" email. Any commit whose author email differs from this is refused. |
| `user.name` | (set by you) | Used by pre-push to identify "commits that claim to be you" (name match) vs contributor commits (name doesn't match). |
| `hooks.bannedEmailsRegex` | unset (scan disabled) | If set, pre-commit refuses any commit whose staged ADDED lines match this regex. Pre-existing content in unmodified parts of files is ignored. Example: `[A-Za-z0-9._%+-]+@(myorg\.com\|me\.com)`. |
| `core.hooksPath` | `~/.config/git/hooks` (set by installer) | Where git looks for hooks. **If a repo's local config sets this**, the global hooks STOP firing for that repo — see Caveats. |

**Switching identities per-repo just works.** If you commit as
`work@employer.com` in work repos and `you@personal.com` in personal ones,
set `git config user.email` per-repo as you already do; the hooks pick
that up automatically and enforce whatever each repo expects.

## Verify

```bash
# Global config in place
git config --global --get core.hooksPath          # → /Users/<you>/.config/git/hooks

# Hooks executable
ls -l ~/.config/git/hooks                          # both files, +x

# Resolved identity (what new commits will use)
git var GIT_AUTHOR_IDENT                           # → <your-name> <your-email>
# Should match `git config user.name` + `user.email`. If it doesn't, an
# env var (EMAIL, GIT_AUTHOR_EMAIL, etc.) is overriding — pre-commit will
# refuse, which is the correct behavior.

# Heal script works
bash ~/.claude/heal-git-hooks.sh                   # silent if nothing to fix

# Effective hooksPath in your current repo (should match global unless local override)
git config --get core.hooksPath
```

To prove the email guard fires, in a throwaway repo:

```bash
git init /tmp/test-hooks && cd /tmp/test-hooks
git config user.name  "Your Name"
git config user.email "you@example.com"
echo hello > a.txt && git add a.txt

# Normal commit — should pass
git commit -m test                                  # ✓

# Simulate the Claude leak pattern — per-command override
GIT_AUTHOR_EMAIL=leak@example.com git commit --allow-empty -m leak
# → refused: "author email differs from configured user.email" ✓
```

## Update

```bash
cd ~/.config/claude-git-hooks && git pull
```

Symlinks pick up the new content immediately — no reinstall step.

## Caveats

- **Repos that set their own `core.hooksPath` bypass the global hooks.** The
  `heal-git-hooks.sh` SessionStart hook catches the Claude EnterWorktree
  variant (self-ref, stale) automatically. Tools like **husky** and
  **lefthook** legitimately set per-repo `core.hooksPath` to `.husky` or
  similar — the heal script preserves these. If you want the email check in
  a husky repo, add the same logic inside `.husky/pre-commit`.
- **Bypass when you mean it:** `git commit --no-verify` and `git push
  --no-verify` skip the hooks. Don't make a habit of it.
- **Multi-line/binary file edge cases in the content scan:** the scan parses
  unified diff additions line-by-line. It won't catch a banned string split
  across lines, and it skips binary files (git's diff format doesn't show
  them). For high-assurance secret scanning use `gitleaks` or `git-secrets`
  alongside.
- **`hooks.bannedEmailsRegex` is interpreted by `awk`'s ERE engine.** No
  Perl-style features (lookaheads, etc.). Test your regex with `echo
  'sample' | awk "/$YOUR_REGEX/"` before relying on it.

## Uninstall

```bash
# Drop the symlinks and global config
rm -f ~/.config/git/hooks/pre-commit \
      ~/.config/git/hooks/pre-push \
      ~/.claude/heal-git-hooks.sh
git config --global --unset core.hooksPath
git config --global --unset hooks.bannedEmailsRegex

# Remove the SessionStart hook from ~/.claude/settings.json
#   (manual edit — find the SessionStart block that calls heal-git-hooks.sh and remove it)

# Optionally delete the clone
rm -rf ~/.config/claude-git-hooks
```

## License

MIT.
