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
#   - local == self-referential default
#     (<gitdir>/hooks, or the common
#     .git/hooks from a linked worktree)  → unset, print one-line INFO
#   - local target doesn't exist (stale)  → unset, print one-line INFO
#   - local target IS a real per-repo
#     hook dir (.husky/.beads/hooks/etc.) → leave alone, exit 0
#
# Never exits non-zero — must not block session start.

set -u
target="${CLAUDE_PROJECT_DIR:-$PWD}"

# Bail silently if not in a git repo.
gitdir=$(git -C "$target" rev-parse --absolute-git-dir 2>/dev/null) || exit 0
# In a linked worktree, --absolute-git-dir is <repo>/.git/worktrees/<name>,
# but hooks live under (and EnterWorktree writes) the COMMON dir's hooks/,
# i.e. <repo>/.git/hooks. Resolve it too so the self-ref check sees both.
# (--git-common-dir may be relative to $target on older git; absolutize.)
commondir=$(git -C "$target" rev-parse --git-common-dir 2>/dev/null || echo "$gitdir")
case "$commondir" in
  /*) ;;
  *)  commondir="$target/$commondir" ;;
esac

cur=$(git -C "$target" config --local --get core.hooksPath 2>/dev/null || true)
[ -z "$cur" ] && exit 0

# Resolve relative paths against the repo root.
case "$cur" in
  /*) abs="$cur" ;;
  *)  abs="$target/$cur" ;;
esac

# Self-ref check: same path as <gitdir>/hooks OR <commondir>/hooks (string OR
# realpath-equivalent, in case symlinks).
self_ref=0
rabs=$(realpath "$abs" 2>/dev/null || echo "")
for default in "$gitdir/hooks" "$commondir/hooks"; do
  if [ "$abs" = "$default" ]; then
    self_ref=1; break
  fi
  rdef=$(realpath "$default" 2>/dev/null || echo "")
  if [ -n "$rabs" ] && [ "$rabs" = "$rdef" ]; then
    self_ref=1; break
  fi
done

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
