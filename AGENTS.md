# Agent instructions for claude-git-hooks

Three git/Claude-Code hooks that prevent Claude from leaking your real
email into commit metadata. Repo is the source of truth; user-side
"installs" are just symlinks from here to `~/.config/git/hooks/` and
`~/.claude/`.

## Repo layout

| Path | Purpose |
|---|---|
| `hooks/pre-commit` | Refuses commits whose author email differs from `git config user.email`. |
| `hooks/pre-push` | For each commit being pushed: if `author.name` matches `git config user.name`, `author.email` must too. |
| `heal-git-hooks.sh` | Claude Code SessionStart hook; unsets self-referential or stale local `core.hooksPath` overrides that Claude's `EnterWorktree` writes. |
| `README.md` | User-facing docs. The Install section has the canonical Claude prompt. |

## Install

If a user asks you to install, follow the prompt in `README.md` § Install
verbatim. It's intentionally explicit, idempotent, and step-by-step. Don't
improvise. Quick summary of what that prompt does:

1. Clone this repo to `~/.config/claude-git-hooks` (or `git pull` if present).
2. Symlink `hooks/pre-{commit,push}` → `~/.config/git/hooks/`; `heal-git-hooks.sh` → `~/.claude/`.
3. `git config --global core.hooksPath ~/.config/git/hooks`.
4. Add `SessionStart` hook to `~/.claude/settings.json` running `bash ~/.claude/heal-git-hooks.sh`.
5. Optionally `git config --global hooks.bannedEmailsRegex '<regex>'` for the content-scan.

## Verify

```bash
git config --global --get core.hooksPath          # → ~/.config/git/hooks
git var GIT_AUTHOR_IDENT                           # → matches git config user.name+email
ls -l ~/.config/git/hooks                          # pre-commit, pre-push, both +x
bash ~/.claude/heal-git-hooks.sh                   # silent if nothing to fix
```

End-to-end leak smoke test in a throwaway repo:

```bash
git init /tmp/test && cd /tmp/test
git config user.name "Test" && git config user.email "you@example.com"
echo x > a && git add a
git -c user.email=leak@example.com commit -m leak     # MUST refuse
git commit -m normal                                   # MUST pass
```

## Uninstall

```bash
rm -f ~/.config/git/hooks/pre-commit \
      ~/.config/git/hooks/pre-push \
      ~/.claude/heal-git-hooks.sh
git config --global --unset core.hooksPath
git config --global --unset hooks.bannedEmailsRegex
# Manually remove the SessionStart block from ~/.claude/settings.json
rm -rf ~/.config/claude-git-hooks                  # optional: delete the clone
```

## Development conventions

- **stdlib bash only.** No Node, Python, jq, ripgrep, pre-commit framework — just `git`/`bash`/`awk`/`sed`/`grep`. The zero-install footprint is part of the value prop.
- **macOS BSD compatibility matters.** Tested on macOS first, Linux second. Two pitfalls already encountered:
  - Multi-char field separators in `awk` are **regexes** — `" | "` is interpreted as "space OR pipe OR space". Use `-F'\t'` with `%x09` in `git log --format`.
  - `&` in `sed` replacement strings is the matched pattern. Escape with `\&` when you mean a literal `&`.
  - `awk -v var=value` **processes escape sequences** in `value` (POSIX behaviour, gawk and mawk alike). A user regex like `myorg\.com` arrives as `myorg.com` (any char), and gawk prints a warning on every commit. Never pass user-supplied patterns with `-v`; read them from `ENVIRON[...]` instead, as `hooks/pre-commit` does.
- **Hooks must read STORED config, not propagated overrides.** Both hooks include a `git_config_stored()` helper that unsets every `GIT_CONFIG_*` env var in a subshell before reading. Without it, `git -c user.email=X commit` propagates the override to the hook's own `git config --get user.email` call — comparing override-vs-override always matches, and the leak slips through silently. Don't simplify this back to a plain `git config --get`.
- **Hooks chain to per-repo `.git/hooks/<name>` if executable.** Don't break the chain — `exec` only after all global checks pass, and guard against recursing into the global itself.
- **No Claude commit attribution.** Don't add `Generated with Claude Code` or `Co-Authored-By: Claude` trailers.

## Things to NOT do

- **Don't add an allowlist regex back to the hooks.** The design is "trust `git config user.email`" — set once with `git config --global` (or `--local` per repo), the hooks enforce it. If someone has multi-identity needs, they use `--local user.email` per-repo; we don't grow a config surface for it. Reference commit `303aeb7` (initial release) for the rationale.
- **Don't make `heal-git-hooks.sh` aggressive.** It MUST preserve real per-repo hook systems (`.husky`, `.beads/hooks`, project-specific dirs with actual hook files). Only self-referential (`= <repo>/.git/hooks`) or stale (target dir missing) overrides get unset.
- **Don't add dependencies.** The point of the project is one bash file per hook with no install ceremony.

## Testing changes

No formal test runner persisted in the repo yet. The README's Verify section
plus the smoke test in `## Verify` above cover the canonical scenarios. When
changing either hook, run through (at minimum):

1. Normal commit (matching identity) → PASS
2. `git -c user.email=X commit` → REFUSE (this is the bug-prone case — see `git_config_stored` above)
3. `GIT_AUTHOR_EMAIL=X git commit` → REFUSE
4. `hooks.bannedEmailsRegex` matching a staged ADDED line → REFUSE. Use a pattern containing `\.`: it must refuse `x@myorg.com`, must NOT match `x@myorgXcom`, and must print no awk warning on stderr.
5. Pre-existing banned content in unmodified file region → PASS (don't false-positive)
6. Push range with contributor commits (different author.name) → contributors PASS; your-name + wrong-email REFUSE
