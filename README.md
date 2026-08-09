# todo

A central capture system for dev/project ideas, driven from Claude Code sessions
(`! todo add …`) or a plain shell. Capture is instant and dumb; a low-tier
`claude -p` call classifies captures later, in a subprocess, so its reasoning
never pollutes the session you captured from.

## Install

```sh
./install.sh          # copies bin/todo -> ~/.local/bin/todo
```

Re-run after editing `bin/todo` (it's a copy, not a symlink). Dev-only by design
— see the note in `install.sh`.

Requires `jq`, `git`, `flock`, and the `claude` CLI on PATH.

## Usage

```sh
todo add <text…>                 # instant capture (no model, no network)
todo classify                    # drain the inbox through the classifier
todo list [--repo X] [--type idea|task] [--all] [--done]
todo show <id>
todo done <id>
todo reopen <id>
todo rm <id>
```

Pushing is intentionally not a command: every mutating command auto-commits
locally, and pushes to GitHub are done manually by the owner (the repo requires
approval to push).

`todo list` is instant and read-only: it never calls the model. It shows
unclassified captures too, with the fields classification would fill in (repo,
type, tags) rendered as `-` and `type` shown as `raw`. Run `todo classify` to
enrich them.

## Data model

Two JSON-lines files, both tracked in git — the history is the archive.

- `inbox.jsonl` — append-only raw captures: `{id, created, text, status:"raw"}`
- `todos.jsonl` — classified records:
  `{id, created, text, title, repo, type, tags, priority, dupe_of, status, done}`

`id` is a zero-padded sequential `t-NNNN`. Every mutating command auto-commits
locally; pushing is done manually by the owner.

## Classification

`todo classify` batches all pending inbox items into a single headless call:

```
claude -p --model haiku --output-format json --disallowed-tools '*' \
  --append-system-prompt classify/system-prompt.md  <payload>
```

The payload is the batch plus the repo list from
`my-system/users/dev/sections/repo-descriptions.md` (override with
`$TODO_REPOLIST`) — the model's only context. It never asks questions; it
defaults every field when unsure (see `classify/system-prompt.md`). Raw input
and output of each call are logged to `logs/` (gitignored) for prompt tuning.

## Desktop capture (ethan)

The Plasma session runs as `ethan`, who can't run the dev-only `todo` binary.
For quick GUI capture, my-system deploys a small reviewed companion,
`todo-capture` (source: `my-system/users/ethan/localbin/todo-capture`), into
ethan's `~/.local/bin`. It only *appends* a raw record to the shared inbox (no
model, no dev-repo code), so classification still happens later via dev's
`todo classify`. Two launchers ship with it: "Todo: Quick Capture" (a `kdialog`
one-field prompt) and "Todo: Capture Clipboard" (`wl-paste`). Global hotkeys are
repo-managed (my-system `users/ethan/kde-global-shortcuts.conf`, asserted by
install.sh): Meta+T for the dialog, Meta+Shift+T for the clipboard.

## Config (env)

| Var                   | Default |
|-----------------------|---------|
| `TODO_DIR`            | `/srv/dev/repos/todo` |
| `TODO_MODEL`          | `haiku` |
| `TODO_FALLBACK_MODEL` | (none) — if set, use a Sonnet-4-or-lower id, never the `sonnet` alias |
| `TODO_REPOLIST`       | `/srv/dev/repos/my-system/users/dev/sections/repo-descriptions.md` |
