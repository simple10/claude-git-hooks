#!/usr/bin/env bash
# SessionStart hook: heal Claude-harness writes that shadow global git hooks.
#
# Background: Claude's EnterWorktree tool (and possibly other harness paths)
# writes `[core] hooksPath = <repo>/.git/hooks` directly into a repo's local
# .git/config — bypassing the `git config` CLI, so it leaves no transcript
# trail. The local setting beats the global `core.hooksPath`, which silently
# disables the user's global pre-commit/pre-push protections (noreply-email
# guard, banned-content scan). This script auto-corrects at session start.
#
# Behavior:
#   - $CLAUDE_PROJECT_DIR not a git repo  → no-op, exit 0
#   - no local core.hooksPath             → no-op, exit 0
#   - local == self-referential default   → unset, print one-line INFO
#   - local target doesn't exist (stale)  → unset, print one-line INFO
#   - local target IS a real per-repo
#     hook dir (.husky/.beads/hooks/etc.) → leave alone, exit 0
#
# Never exits non-zero — must not block session start.

set -u
target="${CLAUDE_PROJECT_DIR:-$PWD}"

# Bail silently if not in a git repo.
gitdir=$(git -C "$target" rev-parse --absolute-git-dir 2>/dev/null) || exit 0

cur=$(git -C "$target" config --local --get core.hooksPath 2>/dev/null || true)
[ -z "$cur" ] && exit 0

# Resolve relative paths against the repo root.
case "$cur" in
  /*) abs="$cur" ;;
  *)  abs="$target/$cur" ;;
esac
default="$gitdir/hooks"

# Self-ref check: same path (string OR realpath-equivalent, in case symlinks).
self_ref=0
if [ "$abs" = "$default" ]; then
  self_ref=1
else
  rabs=$(realpath "$abs" 2>/dev/null || echo "")
  rdef=$(realpath "$default" 2>/dev/null || echo "")
  [ -n "$rabs" ] && [ "$rabs" = "$rdef" ] && self_ref=1
fi

if [ "$self_ref" = 1 ]; then
  git -C "$target" config --local --unset core.hooksPath 2>/dev/null \
    && echo "[heal-git-hooks] unset self-referential core.hooksPath in $target (was: $cur)"
  exit 0
fi

# Stale check: target dir doesn't exist.
if [ ! -d "$abs" ]; then
  git -C "$target" config --local --unset core.hooksPath 2>/dev/null \
    && echo "[heal-git-hooks] unset stale core.hooksPath in $target (was: $cur, target missing)"
  exit 0
fi

# Real per-repo hook system (.husky, .beads/hooks, project-specific): preserve.
exit 0
