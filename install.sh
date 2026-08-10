#!/usr/bin/env bash
#
# install.sh - put `todo` on a user's PATH, by trust tier.
#
# Copies bin/todo into ~/.local/bin (a plain copy, never a symlink). Because the
# copy is decoupled from the repo, re-run this after editing bin/todo to sync.
#
# Two operators:
#   dev            installs into dev's own ~/.local/bin. No review gate — dev
#                  running its own code from a dev-writable repo crosses no
#                  privilege boundary.
#   ethan | root   installs into ethan's ~/.local/bin (privileged), behind a
#                  review gate: bin/todo is diffed against the ethan-approved
#                  origin/master and needs explicit confirmation if it differs.
#                  `todo classify` self-guards to dev, so ethan gets full parity
#                  minus that one dev-only command.
# Any other operator is refused.
#
# SECURITY NOTE (deliberate trade-off, mirrors my-system/users/install.sh):
# the ethan copy is made from the WORKING TREE, which dev can write. A local edit
# to bin/todo therefore reaches ethan on the next deploy — the GitHub merge gate
# does NOT cover local tampering. The review gate below narrows, but does not
# close, that window (it can't gate this script itself, which is also
# dev-writable). sudo/root + ethan's private home remain the real boundary.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SRC="$REPO_ROOT/bin/todo"
ME="$(id -un)"

say(){ printf '%s\n' "$*"; }

path_note() {   # $1 = home whose ~/.local/bin to check (only meaningful for self-installs)
    case ":$PATH:" in
        *:"$1/.local/bin":*) ;;
        *) say "note: $1/.local/bin is not on your PATH" >&2 ;;
    esac
}

# The ethan-approved baseline to diff bin/todo against: current branch's
# upstream, else origin/HEAD's default branch, else a sane fallback.
BASE_REF="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
[ -n "$BASE_REF" ] || BASE_REF="$(git -C "$REPO_ROOT" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
[ -n "$BASE_REF" ] || BASE_REF="origin/master"

# --- review gate: privileged file must match approved upstream, else prompt.
review_gate() {   # $1 = repo-relative path
    local rel="$1"
    git -C "$REPO_ROOT" fetch -q origin 2>/dev/null || true
    if git -C "$REPO_ROOT" rev-parse --verify -q "$BASE_REF" >/dev/null; then
        if git -C "$REPO_ROOT" diff --quiet "$BASE_REF" -- "$rel"; then
            return 0   # matches ethan-approved upstream — no prompt needed
        fi
        say "!! '$rel' DIFFERS from approved $BASE_REF:"
        git -C "$REPO_ROOT" --no-pager diff "$BASE_REF" -- "$rel" || true
    else
        say "!! no upstream ($BASE_REF) to compare against yet: '$rel'"
    fi
    local a; read -r -p "   install this privileged file anyway? [y/N] " a </dev/tty
    [ "$a" = y ] || [ "$a" = Y ]
}

case "$ME" in
    dev)
        # dev-tier: dev's own home, no gate.
        install -D -m 0755 "$SRC" "$HOME/.local/bin/todo"
        say "installed $HOME/.local/bin/todo"
        path_note "$HOME"
        ;;
    ethan|root)
        # ethan-tier: privileged copy into ethan's home, behind the review gate.
        ETHAN_HOME="$(getent passwd ethan | cut -d: -f6)"
        [ -n "$ETHAN_HOME" ] || { say "install.sh: cannot resolve ethan's home" >&2; exit 1; }
        review_gate "bin/todo" || { say "   skipped bin/todo"; exit 1; }
        install -D -m 0755 "$SRC" "$ETHAN_HOME/.local/bin/todo"
        say "installed $ETHAN_HOME/.local/bin/todo (ethan)"
        ;;
    *)
        say "install.sh must be run as dev (self-install) or ethan/root (deploy to ethan)." >&2
        say "current user: '$ME' — refusing." >&2
        exit 1 ;;
esac
