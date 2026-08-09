#!/usr/bin/env bash
#
# install.sh - put `todo` on the current user's PATH.
#
# Copies bin/todo into ~/.local/bin (a plain copy, not a symlink). Because the
# copy is decoupled from the repo, re-run this after editing bin/todo to sync.
#
# This tool is dev-only by design: the Claude `!` path runs as dev, and dev
# running its own code from a dev-writable repo crosses no privilege boundary.
# Do NOT adapt this to install into another user's (e.g. ethan's) home.
set -euo pipefail

src="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/bin/todo"
dest="$HOME/.local/bin/todo"

install -D -m 0755 "$src" "$dest"
echo "installed $dest"

case ":$PATH:" in
    *:"$HOME/.local/bin":*) ;;
    *) echo "note: $HOME/.local/bin is not on your PATH" >&2 ;;
esac
