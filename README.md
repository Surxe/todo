# todo

A central capture system for dev/project ideas, driven from Claude Code sessions
(`! todo add …`) or a plain shell. Capture is instant and dumb; a low-tier
`claude -p` call classifies captures later, in a subprocess, so its reasoning
never pollutes the session you captured from.

## Install

`todo` is put on each user's PATH by the **my-system** repo's `users/install.sh`
(the machine's deploy hub), as a copy of `bin/todo`:

- dev   -> `~dev/.local/bin/todo`    (dev's own home; no review gate)
- ethan -> `~ethan/.local/bin/todo`  (reviewed copy, gated against this repo's
  `origin/master`)

Run that installer as ethan to refresh both after editing `bin/todo` (it's a
copy, never a symlink into this dev-writable tree). The store is shared (group
`developers`, group-writable), and `bin/todo` is generic — so the same binary
serves both users. The one dev-only command is `classify`; it self-guards.

Requires `jq`, `git`, `flock` on PATH for everyone, plus the `claude` CLI for
`classify` (dev only).

## Usage

```sh
todo add <text…>                 # instant capture (no model, no network)
todo classify                    # classify un-classified captures (runs on the home-server when configured)
todo list [--repo X] [--type idea|task] [--all] [--done]
todo show <id>                   # or just `todo <id>` (bare-id shorthand)
todo done <id>
todo reopen <id>
todo rm <id>
todo sync                        # pull + push the shared git hub (best-effort)
```

Every mutating command auto-commits locally. `todo sync` pulls then pushes the
**cross-box hub** (`$TODO_HUB_REMOTE`, a bare repo on the home-server — see
Cross-box). Pushes to **GitHub** remain intentionally manual by the owner (that
remote requires approval to push); the hub is a separate remote.

`todo list` is instant and read-only: it never calls the model. It shows
unclassified captures too, with the fields classification would fill in (repo,
type, tags) rendered as `-` and `type` shown as `raw`. Run `todo classify` to
enrich them.

## Data model

Three append-only JSON-lines streams, all tracked in git — the history is the
archive:

- `captures.jsonl` — `{id, created, text}` — written by `add` (**workstation only**).
- `status.jsonl` — `{id, status: open|done|removed, ts}` — lifecycle events,
  written by `done`/`reopen`/`rm` on **either box**; append-only, latest per id wins.
- `meta.jsonl` — `{id, title, repo, type, tags, priority, dupe_of, classified_at}`
  — written by `classify` (**home-server only**).

`captures.jsonl` and `meta.jsonl` keep a **single writer-box** each, so their
appends never diverge and `git pull --rebase` applies them cleanly. `status.jsonl`
is the exception — both boxes append to it (you can mark something done wherever
you are), so two independent tail-appends would otherwise rebase-conflict. It is
declared `merge=union` in `.gitattributes`: the driver keeps **both** sides' added
lines instead of conflicting, and since the fold takes `max_by(.ts)` per id,
duplicate or out-of-order lines are harmless. This is what keeps cross-box status
conflict-free; do **not** rewrite `status.jsonl` in place (that would reintroduce
real conflicts) — only append.

Two orthogonal axes replace the old coupled status: **classification-state** is
*derived* (an id is classified iff a `meta.jsonl` record exists — classify only
ever appends, never drains or edits), and **completion-status** (`open`/`done`/
`removed`) is its own event stream. `rm` is a `removed` tombstone, not a delete.
`list`/`show` fold the three streams by id at read time.

`id` is a zero-padded sequential `t-NNNN`, minted only by `add` (so a single
writer-box mints ids — no collisions). `next_id` derives from the max capture id
(the local `.seq` is a gitignored cache, never synced).

> Migrating an older two-file store (`inbox.jsonl` + `todos.jsonl`)? Run
> `scripts/migrate-streams.sh` once — it splits the legacy records into the three
> streams, preserving every id's text, classification, and done-state.

## Cross-box (workstation + home-server)

The store is shared between the workstation and the headless home-server via a
**bare git repo on the home-server** (the source of truth; the `hub` remote on
each clone). **Classification runs exclusively on the home-server** (it owns the
`claude` credentials), so `classify` on the workstation is a remote trigger: it
pushes, runs the classify job on the server over SSH (`$TODO_CLASSIFY_REMOTE` →
home-server's `todo/classify-drain.sh`), then pulls the enriched meta back.

### Sync is event-driven, not polled

`bin/todo` itself never touches the network on a mutation — it only commits
locally, keeping `add`/`done` instant. Publishing the commit to the hub is a
**separate, out-of-process systemd job**, so no command ever blocks on ssh:

- **Push on commit (both boxes).** A systemd `.path` unit watches
  `.git/logs/HEAD` and runs `todo sync` (pull+push) on every local commit —
  `todo-sync.path` for dev on the workstation (deployed by *my-system*), and
  `hs-todo-sync.path` on the home-server (deployed by *home-server*). So a change
  on either box reaches the hub the moment it is committed.
- **Fan-out to the workstation.** The hub's bare repo carries a `post-receive`
  hook (installed by *home-server*) that, on any push, best-effort nudges the
  workstation to pull — so server-side changes (fresh `meta`, or a `done` marked
  on the server) propagate to the workstation without it polling. It is
  backgrounded and bounded, and simply no-ops when the workstation is asleep or
  its reverse-ssh alias isn't configured; the workstation then catches up on its
  next own commit-sync. (The workstation reaches the server via the `todo-hub`
  ssh alias; the reverse direction needs a matching `todo-workstation` alias +
  key on the server — kept out of the repos, like `todo-hub`.)
- **The only timer is on the server, for classification** (`hs-todo-classify`),
  not for sync.

All sync is best-effort: an unreachable hub leaves the local commit intact and
warns, so capture never blocks off-network. The classify job's hub pull
(`classify-drain.sh`) **aborts a failed rebase** before continuing, so a bad
sync can never leave conflict markers in a stream (which would break the `jq`
folds). See the my-system and home-server repos for the deploy wiring.

## Classification

`todo classify` batches all un-classified captures (those with no `meta.jsonl`
record, excluding tombstoned ones) into a single headless call:

```
claude -p --model haiku --output-format json --disallowed-tools '*' \
  --append-system-prompt classify/system-prompt.md  <payload>
```

The payload is the batch plus the repo list from
`my-system/users/dev/sections/repo-descriptions.md` (override with
`$TODO_REPOLIST` — the home-server sets this to its own repo list) — the model's
only context. It never asks questions; it defaults every field when unsure (see
`classify/system-prompt.md`). Classify only **appends** to `meta.jsonl`; it never
touches captures or status. Raw input and output of each call are logged to
`logs/` (gitignored) for prompt tuning.

## Desktop capture (ethan)

The Plasma session runs as `ethan`, who now has the full `todo` command (minus
the dev-only `classify`). For quick GUI capture, my-system also deploys
`todo-capture` (source: `my-system/users/ethan/localbin/todo-capture`) into
ethan's `~/.local/bin`: a thin front-end that prompts (`kdialog` / clipboard) and
delegates to `todo add`, so it duplicates none of the store logic. Two launchers
ship with it: "Todo: Quick Capture" (a `kdialog` one-field prompt) and "Todo:
Capture Clipboard" (`wl-paste`). Global hotkeys are repo-managed (my-system
`users/ethan/kde-global-shortcuts.conf`, asserted by my-system's install.sh):
Meta+T for the dialog, Meta+Shift+T for the clipboard.

## Config (env)

| Var                   | Default |
|-----------------------|---------|
| `TODO_DIR`            | `/srv/dev/repos/todo` |
| `TODO_MODEL`          | `haiku` |
| `TODO_FALLBACK_MODEL` | (none) — if set, use a Sonnet-4-or-lower id, never the `sonnet` alias |
| `TODO_REPOLIST`       | `/srv/dev/repos/my-system/users/dev/sections/repo-descriptions.md` |
| `TODO_HUB_REMOTE`     | `hub` — git remote name for the shared bare repo (`todo sync`) |
| `TODO_CLASSIFY_REMOTE`| (none) — if set (e.g. `dev@home-server`), `classify` runs there over SSH instead of locally |
| `TODO_REMOTE_CLASSIFY_CMD` | `todo classify` — the command run over SSH on the classify remote |
| `TODO_SSH_OPTS`       | `-o ConnectTimeout=8 -o BatchMode=yes` — keeps sync non-blocking / non-interactive |
