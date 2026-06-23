---
id: RFC-0028
name: Operation Log, Replay, and Trash
status: Draft
owners:
    - alistairbayley
created: 2026-06-23
updated: 2026-06-23
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Operation Log, Replay, and Trash

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-23       |
| Started   |                  |
| Completed |                  |

## Summary

Give the navigation tree's structural operations (RFC-0027) a recovery and
reproducibility layer, held **outside the document tree**: an append-only
**operation log** of *logical* moves and deletes; **replay** of that log onto a
refreshed corpus to re-apply the reorganisation; **undo** by appending and applying
each operation's inverse; and a **trash** that deletes move to (with provenance) so
they can be restored. The corpus is periodically refreshed from an authoritative
source in its *original* layout; the operation log is the durable overlay that
re-imposes the author's reorganisation after each refresh, and the trash plus the
log's inverses are the recovery net the gitignored tree otherwise lacks.

## Context

RFC-0027 adds in-server move and delete but, because the tree is gitignored, has
**no undo** -- it relies on preview-then-confirm and refusing referenced deletes.
This RFC adds the recovery layer RFC-0027 deferred, driven by two needs the owner
identified:

- **Replay after refresh.** The corpus is periodically re-exported from an
  authoritative source in its *original* structure, overwriting the author's
  in-app reorganisation. A durable, outside-the-corpus log of the logical moves and
  deletes lets the server replay them to re-impose the reorganisation on the fresh
  content. Creates are *not* replayed (new content is authored at the source); the
  log is a **structural overlay**, not a content history.
- **Undo and restore.** Authors need to reverse a mistaken move (apply its inverse)
  and recover a deleted page or section (restore from trash). Neither git nor a
  versioning store is available here yet, so the log's inverses and the trash are
  the recovery mechanisms.

This builds on RFC-0027: its move/delete operations are what the log records and
what replay/undo/restore re-apply. The log and trash live outside the tree (a
server-owned, configurable location), keeping the corpus clean -- consistent with
the navigation tree reading the filesystem live (ADR-059) and never writing
generated state into the tree.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- An append-only **operation log**, outside the corpus, of logical move and delete
  operations (kind + paths + slug + timestamp + sequence), not file-level diffs.
- **Replay** the log onto a refreshed (original-layout) corpus in order, applying
  each operation through RFC-0027's machinery; best-effort, skipping and reporting
  operations whose precondition no longer holds.
- **Undo** as append-inverse: applying an operation's inverse (a move's reverse
  move; a delete's restore-from-trash) and logging that inverse, so the log is a
  faithful append-only history and replay reproduces the net state.
- **Trash**: deletes move the page/section (with its sidecar and exclusive assets)
  to an outside-the-corpus trash with a provenance record; **restore** puts it back
  via RFC-0027's move machinery, refusing if the original location is occupied.

## Non-Goals

- **Content history / versioning.** The log records structure, not page bodies or
  edits; replay does not reproduce content (a refresh supplies that). The eventual
  git-based versioning store is separate.
- **Replaying creates.** New pages are authored at the source; the log replays only
  moves and deletes.
- **Out-of-order / arbitrary undo.** Undo appends the inverse of operations; this
  RFC does not add dependency analysis to safely revert an arbitrary earlier
  operation in isolation (it is reverted by appending its inverse like any other).
- **Automatic trash GC.** Trash retention/purge policy is future; trash grows until
  manually cleared.

## Proposal

### The operation log

An append-only log at a configurable, outside-the-corpus path (e.g.
`operation_log`), one **logical operation** per line (JSON):

- `type`: `move` | `delete` | `restore`
- `kind`: `page` | `section`
- `from` / `to`: tree-relative paths (a `move` has both; `delete` has `from` only;
  `restore` has `to` -- its origin -- and a trash reference)
- `slug` change is implicit in `from`/`to`
- `seq`: a monotonic sequence number; `ts`: a timestamp (stamped by the caller, as
  scripts cannot read the clock -- ADR-style note)
- `trash`: for `delete`/`restore`, the trash entry id

The log records *intent*, not the file-by-file link rewrites or asset moves -- those
are recomputed by RFC-0027's machinery when the operation is applied (live, on
undo, or on replay). Every navigation-tree move and delete appends one record;
**undo** appends the inverse record (and applies it). The log is therefore a
complete append-only history -- a move and its later undo both appear and cancel
out on replay.

### Undo (append-inverse)

Undo is uniform: take an operation, build its inverse, apply the inverse through
RFC-0027, and append the inverse to the log.

- Inverse of `move(from -> to)` is `move(to -> from)`.
- Inverse of `delete(from)` is `restore(from)` from the trash entry.
- Inverse of `restore(to)` is `delete(to)`.

There is no separate undo state -- the inverse is just another logged operation, so
"redo" is undoing the undo. (Out-of-order undo is a non-goal; appending an inverse
is always well-defined, but reverting a non-latest operation may not produce the
intent if later operations depended on it.)

### Replay

Replay applies the log in `seq` order to a refreshed corpus (assumed to be in the
original source layout), each operation going through RFC-0027's move/delete:

- **Best-effort**: if an operation's precondition does not hold -- its `from` is
  missing (the source removed it, or a prior op already moved it), or its `to` is
  occupied -- the operation is **skipped and recorded in a replay report**; replay
  continues. One upstream change never half-breaks the corpus.
- **Per-op postcondition** (not a whole-tree diff): after applying an operation,
  replay asserts its postcondition (the source moved away, the target now present)
  and records any failure in the report. There is no separate structural-identity
  check against an expected net state -- the report covers the real failure modes.
- The report lists every skipped operation and postcondition failure with the
  reason, for operator review.
- Replay is intended for a *fresh* (original-layout) corpus; running it against an
  already-reorganised tree simply skips most operations (sources already moved).

### Trash

A delete moves the target into a configurable trash root (`trash_root`) rather than
destroying it. The trash root is **outside the served corpus but on the same
filesystem**, so a delete is a single `rename(2)` and a source refresh (which
re-exports the corpus in its original layout) never wipes it -- the reason it cannot
live inside the tree. It is browsable and recoverable through a **Trash view** in
the navigation tree that reads the trash root (not by placing trash in the tree).

- **What moves**: for a **page**, its `.md`, its sidecar **meta directory**, and its
  **exclusive assets** (shared assets stay, per RFC-0027); for a **section**, the
  whole folder (its pages, `meta/`, `assets/`, subtree). Each trashed item is a
  trash entry (id + timestamp) with a **provenance** manifest: the original tree
  path, kind, and the originating log `seq`.
- **Refuse-if-referenced still applies** (RFC-0027): trash recovers content but does
  not fix the dangling links a referenced delete would leave, so a referenced delete
  is still refused.
- **Restore** is the inverse: move the trashed content back to its provenance path
  via RFC-0027's move machinery (re-adding the parent **index.md listing** entry),
  **refusing if the original location is now occupied** and prompting for a new
  location/slug (consistent with move-collision). Restore appends a `restore`
  operation to the log.

### Relationship to RFC-0027

RFC-0027 owns the move/delete operations and their link/asset/listing
reconciliation; this RFC owns the log, replay, undo, and trash that wrap them.
RFC-0027's delete routes its destruction to this RFC's trash (rather than a hard
`unlink`/`rmdir`), so delete is only fully realised once trash exists; the two are
implemented together for delete. (If delete were to ship before trash, it would
hard-delete as an interim -- undesirable given no undo net, so trash-first is
preferred.)

## Alternatives Considered

- **Rely on a git-based versioning store now**: not yet available; the log + trash
  are the interim (and remain useful as a *structural-intent* overlay even once
  versioning exists, because they capture reorganisation intent, not byte diffs).
- **LIFO undo that pops the log**: rejected in favour of append-inverse -- the owner
  wants a faithful append-only history; popping would lose the record that an
  operation was made and undone.
- **Hard delete (RFC-0027 interim)**: rejected as the end state -- with no undo net,
  destroying content is too risky; trash makes deletes recoverable.
- **Logging physical diffs** (every rewritten file): rejected -- the log is logical
  intent, replayable through the same machinery; storing diffs would couple the log
  to a corpus state and bloat it.
- **Replaying creates (and thus content)**: rejected -- pushes the log toward a
  content history; content comes from the source refresh.

## Security Impact

- The log and trash live outside the corpus at configured paths; their paths are
  operator config, not request-derived. Restore/replay targets pass RFC-0027's
  `safeComponent` validation before any filesystem write, so a crafted log/trash
  entry cannot escape the tree root on apply.
- No new authentication; inherits the server's current posture.

## Reliability Impact

- **Append-only durability**: the log is the recovery record; a failed append must
  surface (a move applied but not logged loses replay/undo for it). The order is
  **apply-then-append** with failure reporting -- a crash between the two loses at
  most one log entry rather than corrupting the tree (an applied-but-unlogged op).
- **Replay best-effort** never half-breaks the corpus; the report captures gaps.
- **Trash growth**: unbounded until manual purge (GC is a non-goal); the operator
  manages retention.
- **Partial apply** within one operation is RFC-0027's concern (it reports
  per-file failures); the log entry is written for the operation as a whole.

## Compatibility Impact

- New config keys: `operation_log` (path) and `trash_root` (path), both outside the
  served corpus but on the same filesystem, with safe defaults under the app's data
  dir.
- Reverses RFC-0027's "no operation log / no undo / no trash" non-goals; RFC-0027's
  delete is updated to route to trash.
- No new MicroHs capability beyond RFC-0027's (`rename`/`unlink`/`rmdir`); moving to
  trash is a single `rename(2)` (trash is on the same device, so no copy+remove
  fallback is needed).

## Testing and Quality Gates

- `make check` and `make editor-check`.
- Server (hspec): logical-record round-trip (parse/serialise a log line); inverse
  generation for `move`/`delete`/`restore`; replay ordering, best-effort skip
  (missing `from`, occupied `to`), and per-op postcondition checks in the report;
  trash store (page: md + meta +
  exclusive assets; section: whole folder) and provenance manifest; restore to a
  free origin and refusal when occupied; refuse-if-referenced still blocks a delete.
  Filesystem cases use a `build/` fixture corpus + fixture log/trash dirs.
- Client (vitest): undo affordance, restore-from-trash listing, replay report
  rendering.

## Rollout Plan

1. **Phase 1 -- Operation log.** The logical-record type, append-only writer/reader
   at the configured path, and recording every RFC-0027 move/delete. No replay/undo
   yet.
2. **Phase 2 -- Trash.** Delete routes to `trash_root` with a provenance manifest;
   restore (refuse-if-occupied) via RFC-0027's move machinery.
3. **Phase 3 -- Undo.** Inverse generation for move/delete/restore; apply-and-append.
4. **Phase 4 -- Replay.** Ordered, best-effort replay onto a refreshed corpus with a
   report.
5. **Phase 5 -- Client UX.** Undo affordance, a trash view with restore, and a
   replay trigger + report surface.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or its design contracts do not
  cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if
  another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- (Resolved 2026-06-23) **Append order**: apply-then-append -- a crash between the
  two loses at most one log entry and never corrupts the tree.
- (Resolved 2026-06-23) **Trash device**: `trash_root` is co-located with the
  corpus (same filesystem), so a delete is a single `rename(2)`; no copy+remove
  fallback is needed (it is outside the *served* tree but on the same device).
- (Resolved 2026-06-23) **Replay verification**: no whole-tree structural diff;
  replay records each operation's postcondition (source moved, target present) in
  the report, which covers the real failure modes cheaply.

## Implied Decision Records (to add on acceptance)

- **ADR-064**: Structural reorganisation is captured as an append-only logical
  **operation log** outside the corpus, replayable onto a refreshed source export;
  undo is append-inverse, not a popped stack.
- **ADR-065**: Deletes move to an outside-the-corpus **trash** with provenance
  (restore via the move machinery), rather than hard-deleting; refuse-if-referenced
  still applies.

## CONTEXT.md additions (recorded during grilling)

- **Operation log** -- the append-only, outside-the-corpus log of logical moves and
  deletes; replayed on a refreshed corpus; undo appends inverses.
- **Trash** -- where deleted pages/sections go (with provenance) so they can be
  restored.
