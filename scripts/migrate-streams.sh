#!/usr/bin/env bash
#
# migrate-streams.sh — one-time conversion from the legacy two-file store
# (inbox.jsonl + todos.jsonl) to the three append-only streams
# (captures.jsonl, status.jsonl, meta.jsonl) used by the cross-box `todo`.
#
#   inbox/todos record  -> captures.jsonl  {id, created, text}          (every id)
#   todos record        -> meta.jsonl      {id, title, repo, type, tags,
#                                           priority, dupe_of, classified_at}
#   todos record w/ done -> status.jsonl   {id, status:"done", ts:<done>}
#
# Open/unclassified items need no status event — fold() defaults to "open".
# classified_at is backfilled from the record's `created` (the legacy store kept
# no classify timestamp). Records are emitted sorted by numeric id.
#
# Idempotent guard: refuses if captures.jsonl already exists non-empty (already
# migrated) unless --force. Does NOT commit — it stages nothing and leaves git to
# you, so you can review the diff and commit on a branch.
set -euo pipefail

TODO_DIR="${TODO_DIR:-/srv/dev/repos/todo}"
FORCE=0
[ "${1:-}" = --force ] && FORCE=1

OLD_INBOX="$TODO_DIR/inbox.jsonl"
OLD_TODOS="$TODO_DIR/todos.jsonl"
CAPTURES="$TODO_DIR/captures.jsonl"
STATUS="$TODO_DIR/status.jsonl"
META="$TODO_DIR/meta.jsonl"

die() { printf 'migrate: %s\n' "$*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
[ -d "$TODO_DIR" ] || die "TODO_DIR does not exist: $TODO_DIR"
[ -f "$OLD_INBOX" ] || [ -f "$OLD_TODOS" ] || die "no legacy store (inbox.jsonl/todos.jsonl) in $TODO_DIR"

if [ -s "$CAPTURES" ] && [ "$FORCE" -ne 1 ]; then
    die "captures.jsonl already exists and is non-empty — looks already migrated (use --force to overwrite)"
fi

by_id='sort_by(.id | ltrimstr("t-") | tonumber)'

# captures: every id from both legacy files.
jq -s "$by_id | map({id, created, text}) | .[]" -c "$OLD_INBOX" "$OLD_TODOS" 2>/dev/null > "$CAPTURES" || : > "$CAPTURES"

# meta: one record per classified (todos.jsonl) id; classified_at <- created.
if [ -f "$OLD_TODOS" ]; then
    jq -s "$by_id | map({id, title, repo, type, tags, priority, dupe_of, classified_at: .created}) | .[]" \
        -c "$OLD_TODOS" > "$META" || : > "$META"
else
    : > "$META"
fi

# status: a "done" event for every completed legacy item (ts <- its done time).
if [ -f "$OLD_TODOS" ]; then
    jq -s "$by_id"' | .[] | select(.done != null) | {id, status:"done", ts:.done}' \
        -c "$OLD_TODOS" > "$STATUS" 2>/dev/null || : > "$STATUS"
else
    : > "$STATUS"
fi

printf 'migrated -> %s\n' "$TODO_DIR"
printf '  captures.jsonl: %s\n' "$(wc -l < "$CAPTURES")"
printf '  meta.jsonl:     %s\n' "$(wc -l < "$META")"
printf '  status.jsonl:   %s (done events)\n' "$(wc -l < "$STATUS")"
echo
echo "next: review, then remove the legacy files and commit on a branch, e.g."
echo "   git -C '$TODO_DIR' rm inbox.jsonl todos.jsonl"
echo "   git -C '$TODO_DIR' add captures.jsonl status.jsonl meta.jsonl"
echo "   git -C '$TODO_DIR' commit -m 'store: migrate to three-stream model'"
