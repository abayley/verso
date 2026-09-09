---
id: RFC-0028
name: Operation Log, Replay, and Trash
status: Implemented
owners:
    - alistairbayley
created: 2026-06-23
updated: 2026-08-06
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Operation Log, Replay, and Trash

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-23       |
| Started   | 2026-06-24       |
| Completed | 2026-06-24       |

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
the navigation tree reading the filesystem live (ADR-0059) and never writing
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
- **Dependency-aware out-of-order undo.** The undo picker (Phase 3) lets the author
  invert *any* logged move, not only the latest, by appending its inverse. This RFC
  does **not** add dependency analysis: inverting an earlier move that later
  operations depended on may not reproduce the intended net state, and an inverse
  whose item has since moved or been deleted is **refused cleanly** (the move
  machinery's collision/not-found guard) rather than forced. Choosing a still-valid
  inverse is always well-defined; reasoning about interactions between non-adjacent
  operations is left to the author.
- **Background trash GC.** Retention remains a lazy sweep when trash is read; no
  timer or background worker is introduced.

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
"redo" is undoing the undo. The undo picker lets the author invert any logged move,
not only the latest (it selects the operation by `seq`); appending an inverse is
always well-defined, but reverting a non-latest operation may not produce the intent
if later operations depended on it, and an inverse whose item has since moved is
refused cleanly (no dependency analysis -- see Non-Goals).

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

### Warm operation catalogue

The server opens one warm operation catalogue before it starts serving requests.
The catalogue reads and fully evaluates the append-only log once, owns sequence
allocation and durable appends, and supplies every request-time operation read.
Each successful append writes the durable record before publishing the same record
to in-memory readers. Structural mutations already hold the server write lock, so
sequence allocation and append cannot interleave with another mutation.

The operation log remains the source of truth. The catalogue is derived state and
is rebuilt on restart. Direct route tests use an uncached adapter through the same
interface, while the production application supplies the warm catalogue.

`GET /operations` without query parameters remains the complete append-order log.
The optional `type` filter accepts `move`, `delete`, or `restore`. A non-negative
`limit` selects the newest matching records while preserving append order in the
response. The recent Undo menu requests `GET /operations?type=move&limit=10`; the
full Undo page remains unbounded.

### Warm trash catalogue

The server builds a derived, in-memory trash catalogue before it starts serving
requests. Startup reads every trash manifest once and joins deletion timestamps
from the warm operation catalogue. The trash catalogue holds entries newest-first
and answers subsequent trash listings without walking the trash root.

The trash manifests and operation log remain the source of truth. The catalogue is
not persisted and is rebuilt on every server start, so a crash or an offline replay
is repaired by restart. Out-of-band changes made while the server is running are
outside the live freshness contract; replay is already an offline workflow.

Every in-server delete, restore, undo, retention purge, permanent delete, and empty
operation updates the catalogue while holding the structural write lock. The recent
trash dropdown requests `GET /trash?limit=10`; the full trash page reads the complete
catalogue. Undo remains lazy because opening its menu now reads a small filtered
slice from the warm operation catalogue.

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
- **Trash growth**: when retention is enabled, the lazy sweep evaluates catalogue
  entries without rescanning manifests or the operation log. With retention
  disabled, trash grows until the operator empties or permanently deletes entries.
- **Catalogue recovery**: the catalogue is disposable derived state. Restart
  reconstructs the operation catalogue from the log, then reconstructs the trash
  catalogue from manifests plus those operations. A restart repairs both after a
  crash or offline replay.
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
- `GET /trash` remains backward compatible. An optional non-negative `limit` query
  returns only that many newest entries; omitting it returns the full list.
- `GET /operations` remains backward compatible. Optional `type` and non-negative
  `limit` query values select a newest matching slice for recent menus; omitting
  both returns the complete append-order log.

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
  rendering, and no trash or undo request until its menu opens.
- Warm catalogue (hspec): startup rebuild and newest-first ordering, in-memory reads
  after startup, operation append and sequence consistency, bounded recent move and
  trash listings, and consistency after every trash mutation.

## Rollout Plan

1. **Phase 1 -- Operation log.** [DONE] `MicroHttp.OperationLog`: the logical-record
   type (`Operation`/`OpType`), render/parse round-trip, append-only writer/reader at
   the configured path, and `nextSeq`. The tree-move endpoint records a `move` record
   after a successful applied move (apply-then-append; previews/refusals log nothing),
   with config keys `operation_log` and `trash_root` threaded through `treeRoutes`.
   Replay/undo and delete-logging come in later phases.
2. **Phase 2 -- Trash.** [DONE] `MicroHttp.Trash` (provenance manifest: each stored
   item carries its origin tree path and the removed listing line, so restore is a
   uniform inverse) plus `MicroHttp.TreeMove.deleteTarget`/`restoreFromTrash`. A
   delete moves the target into a `trash_root/<seq>` entry (the trash id is the delete
   op's seq); restore moves every item back to its origin, refuses if the origin is
   occupied, re-inserts the preserved listing entry, removes the entry, and logs a
   `restore` op. Endpoints `POST /tree/*path?delete` and `POST /trash/*id`.
3. **Phase 3 -- Undo.** [DONE] `POST /undo` applies the inverse of a logged operation
   through the existing machinery -- reverse move (`moveSection`/`movePage`),
   `restoreFromTrash` for a delete, `deleteTarget` for a restore -- and appends the
   inverse as a new record (undo is itself logged, so a further undo is a redo). A
   `seq` form field selects which operation to invert; the client surfaces this as an
   **undo picker** (`GET /operations` lists the logged moves, most recent first; the
   nav-tree Undo button opens a drop-down and choosing a move generates its inverse).
   Without `seq` the latest operation is inverted. A `409` when the log is empty, the
   seq is unknown, or the inverse cannot apply (occupied/missing/now-referenced) --
   inverting a non-latest move whose item has since moved refuses cleanly rather than
   corrupting the tree (see the relaxed Non-Goal below).
4. **Phase 4 -- Replay.** [DONE] `MicroHttp.TreeMove.replayLog`: applies the log in
   `seq` order through the move/delete/restore machinery, best-effort -- an op whose
   precondition fails (source missing, destination occupied, now-referenced) is
   skipped and recorded, replay continues. A delete reuses the op's recorded trash id
   so a later restore finds the entry; replay does not append to the log. Replay is an
   **operator command-line action** (`make replay-tool` / `build/replay-tool`,
   `src/ReplayTool.hs`), reading the same config as the server, **not** a web endpoint
   -- it is run after a corpus refresh, typically with the server down, so it operates
   on the filesystem directly and prints the report.
5. **Phase 5 -- Client UX.** [DONE] Nav-tree header buttons: **Undo** -- a drop-down
   listing the logged moves most-recent-first (`GET /operations`), choosing one
   generates and applies its inverse (`POST /undo` with that `seq`), following the open
   document if it moved -- and **Trash** (a view listing `GET /trash` entries, each
   with a Restore button calling `POST /trash/<id>`). Each surfaces the server's
   message in the notice area and refreshes the tree. Replay is intentionally **not**
   in the UI (it is the `replay-tool` CLI, an operator action). Browser-verified
   against a scratch tree.
6. **Phase 6 -- Warm operation and trash catalogues.** [DONE] Remove page-start
   trash and undo requests while keeping both menus lazy. Build one operation
   catalogue and the derived trash catalogue at server startup, serve bounded
   recent menu data, and maintain both catalogues across in-server mutations.

   - [x] Navigation mount performs no trash or undo request; opening a menu loads it.
   - [x] Startup rebuilds a newest-first catalogue and subsequent reads stay in memory.
   - [x] One operation catalogue owns startup read, sequence allocation, append, and
     request-time reads; the trash catalogue consumes the same held operations.
   - [x] The recent-trash endpoint limit and full trash page return the right entries.
   - [x] The recent Undo menu requests ten filtered moves while the full operation
     endpoint and Undo page remain compatible.
   - [x] Delete, restore, undo, retention purge, permanent delete, and empty keep the
     catalogue current.
   - [x] Full quality gate and browser verification pass.

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

- **ADR-0064**: Structural reorganisation is captured as an append-only logical
  **operation log** outside the corpus, replayable onto a refreshed source export;
  undo is append-inverse, not a popped stack.
- **ADR-0065**: Deletes move to an outside-the-corpus **trash** with provenance
  (restore via the move machinery), rather than hard-deleting; refuse-if-referenced
  still applies.

## CONTEXT.md additions (recorded during grilling)

- **Operation log** -- the append-only, outside-the-corpus log of logical moves and
  deletes; replayed on a refreshed corpus; undo appends inverses.
- **Trash** -- where deleted pages/sections go (with provenance) so they can be
  restored.
