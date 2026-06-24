---
id: RFC-0029
name: In-Memory Link Index
status: Draft
owners:
    - alistairbayley
created: 2026-06-24
updated: 2026-06-24
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# In-Memory Link Index

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-24       |
| Started   |                  |
| Completed |                  |

## Summary

Add a server-side **link index** -- the document tree's resolved `.md`->`.md` link
graph, held in memory: for each page its outbound `.md` link targets, and the
inverse, a map from each tree path to the pages that link to it. Move and delete
consult the index to find referrers and the files a move must rewrite, instead of
reading and link-parsing every `.md` on each operation. The index is built once (the
cost a single scan already pays), persisted as a startup cache, maintained
incrementally by the in-server mutations that already know what changed (save,
create, move, delete, restore), and rebuilt -- by a periodic cron-triggered,
server-side rebuild -- to absorb out-of-band changes (notably the periodic document
tree refresh). Expected outcome: move/delete drop from a whole-tree scan to an index
lookup (seconds to milliseconds at the current ~3,900-page scale, and flat as the
document tree grows).

## Context

RFC-0027's move and delete must find, across the **whole** tree, every page whose
relative links resolve to the target (delete's refuse-if-referenced; move's link
rewrite). With no index, each operation reads every `.md` and parses its links.
Measured on the reference document tree (~3,900 `.md` files, some link-dense and up to
~260 KB), parsing all of them took **~86 s** per operation -- so a delete appeared to
hang and the client never saw a response. RFC-0027 mitigated this with a byte
pre-filter (only unpack and parse files whose raw bytes contain the target's
slug/filename), bringing it to **~3.5 s**, now dominated by the unavoidable read of
every `.md`. That is acceptable today but grows linearly with the document tree, and every
move/delete/replay pays it.

ADR-059 (RFC-0026) deliberately chose a **live filesystem read with no cached
index**, reasoning that the tree is the source of truth, is edited out-of-band, and
that a materialised index is a cache that drifts and needs a
persistence/reconciliation story -- buying search, not speed, at the tree size then
considered. Two things have changed: (1) RFC-0027 added whole-tree operations whose
cost ADR-059 did not weigh (it considered only per-folder expansion, which stays
cheap), and (2) the read-everything floor is now the binding constraint on those
operations. RFC-0026 explicitly anticipated this: "an index, if ever wanted for
search, slots in behind the same endpoint as its own RFC, wasting none of this
work." This is that RFC. It **amends** ADR-059 for whole-tree queries while keeping
the nav tree's lazy per-folder live read unchanged.

The drift concern ADR-059 raised is real and is the crux of the design: the served
document tree is **periodically re-exported from an authoritative source in its original
layout** (RFC-0028), and may be edited directly out-of-band. Any index is a derived
cache that must be rebuilt or reconciled after such changes; the design below treats
the index as exactly that -- a rebuildable cache, not a second source of truth.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it
as complete in the phase checklist.

## Goals

- A **resolved `.md`->`.md` link graph** of the document tree: per page, its outbound
  in-tree `.md` link targets (tree-absolute), built by reusing the RFC-0027 link
  engine (`MicroHttp.DocumentLinks`). Not asset edges (asset analysis is folder-local).
- An **inverted referrer map** (`tree path -> referring pages`) so move and delete
  answer "who links to X / into this subtree" by lookup, not by scanning.
- **In-memory** storage held behind a single accessor so callers do not touch the
  filesystem to ask, with a **persisted copy as a startup cache** so a restart does
  not pay a full rebuild.
- **Incremental maintenance**: each in-server mutation (save, create, move, delete,
  restore) updates the index for exactly the pages it changed, and re-persists.
- A **freshness model identical to the navigation tree's (ADR-059)**: the index is
  authoritative for what the server knows (its build plus in-server mutations);
  out-of-band changes (the document-tree refresh, direct edits) appear on the next
  **rebuild**, not live.
- **Single writer.** Only the running server mutates the index/persisted copy. A
  periodic external **cron triggers a server rebuild** (`POST /index/rebuild`); the
  server rebuilds from the **document tree**, swaps its in-memory index, re-persists,
  and **logs when the rebuild differs from the prior index** (a drift signal). This
  bounds out-of-band staleness to the cron interval without a lost-update race.
- Move/delete/replay consult the index; the byte-prefiltered scan
  (`enumerateRelevant`) remains the build path and the correctness fallback.

## Non-Goals

- **Search of any kind.** Whole-tree/full-text/semantic search is a separate, future
  system -- an embedding-vector + full-text store the documents are indexed into
  independently -- not this link graph. The index carries no titles or body text.
- **Replacing the nav tree's lazy live read.** Per-folder expansion stays a live
  `GET /tree` read (ADR-059); the index serves only the whole-tree link queries
  (referrers, rewrite sets), not folder listing.
- **Asset edges / non-link metadata.** Asset ownership (exclusive/shared) is settled
  folder-locally and needs no whole-tree index; sidecar/asset-byte indexing is out.
- **A query language or external query API.** Internal move/delete lookups only.
- **Cross-process / multi-server coherence.** Single-process server; the index lives
  in that process (and the cron triggers *it*, never writes the file itself).

## Proposal

### What is indexed

A pure value computed from the document tree -- the `.md`->`.md` link graph and
nothing else:

- `outbound :: Map PagePath [TreePath]` -- each page's resolved in-tree `.md` link
  targets (the `[text](...)` links `DocumentLinks.pageLinks` + `resolveTarget` already
  yield), tree-absolute. **Not** `assets/<name>` refs: asset ownership is a
  folder-local question (the **Exclusive asset / shared asset** analysis scans only
  the moved page's peers, never the whole tree), so asset edges would add size for no
  whole-tree benefit.
- `inbound :: Map TreePath [PagePath]` -- the inverse: every page that links to a
  given tree path. This is the referrer map move/delete need.

`inbound` is derived from `outbound`; storing both lets a mutation update the inverse
without a full rebuild. Section-level questions ("who links into subtree S") are a
prefix query over `inbound` keys (S and its descendants), exactly the predicate
`referrersMatching` already encodes. The index carries no titles -- search is a
separate, future concern (an embedding-vector + full-text store indexed independently,
not this link graph).

### Lookups the index serves

- **Delete refuse-if-referenced**: `inbound` for the target (page) or the subtree
  (section), minus the parent listing entry and, for a section, the subtree's own
  pages -- the existing `referrersMatching` semantics, now over the index instead of
  a fresh scan.
- **Move rewrite set**: the pages a move must rewrite are exactly the moved subtree's
  pages plus `inbound` of the moved paths -- the index returns the candidate set,
  then the existing `planMoveRewrites`/`planPageMove` compute the byte-precise edits
  on just those pages.

The index narrows *which* pages to process; the pure engines
(`DocumentLinks`/`DocumentListing`) still compute the exact edits, so correctness is
unchanged and the index is a performance layer, not a second implementation.

### Storage and lifecycle

- The index lives in an `MVar` (or equivalent) created at server start, with a
  **persisted copy** outside the document tree (same constraints as the operation log
  and trash). **Startup loads the persisted copy** for an instant start, then kicks a
  **background rebuild from the tree** so a restart never pays the full scan up front
  yet self-corrects within seconds; a move/delete in that brief window carries the
  same bounded risk the freshness model already accepts.
- **Incremental maintenance**: after a mutation, the index is updated for **every page
  the operation wrote** -- not just the moved/deleted item. A move rewrites links in
  its referrers and (for a section) its subtree pages, changing *their* `outbound`
  too; the operation already computes that whole write-set (the rewrite plan), so
  maintenance re-derives `outbound` from the **new** bytes for each page in it and
  patches `inbound`. A save re-derives one page; create adds a page; delete removes
  the target and patches the referrers it touched. Maintenance runs after the
  filesystem mutation commits and re-persists. The **index == full-rebuild** invariant
  (asserted in tests after mutation sequences) is the anti-drift gate.
- **Single writer.** Only the running server mutates the index and its persisted copy
  -- there is no second process writing the file, so no lost-update race. A full
  rebuild always reads the **document tree** (the source of truth), so it captures
  in-server *and* out-of-band changes alike.
- **Out-of-band changes and the cron.** A document-tree refresh or direct edit is not
  seen by incremental maintenance. A periodic external **cron triggers the server's
  rebuild** (`POST /index/rebuild`): the server rebuilds from the tree, swaps the
  in-memory index, re-persists, and **logs when the result differs from the prior
  index** -- a drift signal turning "compare and update if they differ" into an
  operational alert. This bounds out-of-band staleness to the cron interval. It
  mirrors ADR-059's contract (out-of-band changes appear on the next *rebuild*, not
  live) and is the explicit trade this RFC makes versus a never-stale live read. The
  rebuild is also exposed for manual invocation (the refresh workflow that runs
  `replay-tool` can trigger it).

### Relationship to RFC-0027's byte pre-filter

`enumerateRelevant` (RFC-0027) stays: it is the index's build/rebuild path (read +
filter + parse), and a correctness fallback if the index is unavailable or a caller
opts out. Move/delete first consult the index; the pre-filtered scan is the
ground-truth rebuild. The two share `DocumentLinks`, so they cannot diverge in how a
link resolves.

### Boundaries

A new pure module owns the index type and its update functions (build from
`[(PagePath, body)]`, apply a per-page change, query referrers/rewrite-set) so the
graph logic is unit-tested without IO. A thin IO layer owns the `MVar`, the
build-from-tree, and the maintenance hooks the mutation handlers call. No new
MicroHs capability is required (it is parsing and `Map`s over data the link engine
already produces).

## Alternatives Considered

- **Keep the byte-prefiltered scan only (RFC-0027 status quo).** Simplest, no
  drift/maintenance, correct. Rejected as the *end* state because it reads every
  `.md` on every move/delete/replay (~3.5 s now, linear growth); acceptable as the
  fallback/build path, not the steady-state lookup.
- **In-memory only, no persistence.** Avoids a persisted-staleness story. Rejected:
  with the **single-writer** model the staleness concern dissolves (the server is the
  only writer; a full rebuild always reads the tree), so persistence is a safe startup
  cache that avoids paying the full scan on every restart. The persisted copy is
  loaded then background-rebuilt, so a stale-on-load cache self-corrects in seconds.
- **A second process (the cron) rebuilds the persisted file directly.** Rejected: two
  writers (server-incremental + cron) race and lose updates, and it duplicates the
  index-build logic outside the server. The cron instead *triggers* the server's
  rebuild (single writer).
- **FFI `stat(2)` for an mtime fingerprint** to auto-detect out-of-band drift per
  operation. Rejected for v1: mhs has no cheap mtime (no `getModificationTime`), the
  struct layout is platform-specific (the project's socket-portability scars), and
  the cron-bounded operational model closes the same gap without it.
- **Materialised index as the tree's source for listing too** (replace the live
  read). Rejected: ADR-059's reasoning still holds for per-folder expansion (cheap
  live, always correct, no drift); only whole-tree queries justify the index.
- **Build a search index instead** (titles/text, not the link graph). Rejected: it
  would not address the motivating move/delete cost (which is the link graph), and
  search is a separate future system (embeddings + full-text), its own RFC.

## Security Impact

- The index holds only tree paths derived from files already served; it exposes no
  new data and adds no disclosure surface beyond existing reads.
- All paths entering the index come from the validated tree walk
  (`resolveStaticPath`/`safeComponent`); the index introduces no new write surface
  (it is read-derived). Inherits the server's current no-auth posture unchanged.

## Reliability Impact

- **Staleness is the primary risk.** A stale index could miss a referrer (a delete
  wrongly allowed) or a rewrite target (a move leaving a dangling link). Mitigations:
  (1) incremental maintenance for all in-server mutations; (2) rebuild on the
  out-of-band refresh; (3) the pre-filtered scan remains the ground truth and can
  back-stop a high-stakes operation (e.g. verify a delete's "no referrers" against a
  scan before destroying) -- a tunable safety/perf trade recorded in Open Questions.
- **Build cost** is one whole-tree scan (today's per-op cost) at startup/first use
  and per rebuild; bounded and observable (log build time/size).
- **Memory**: the graph is paths + small lists, not bodies -- order the count of
  links across the document tree (megabytes at the current scale), well within budget.
- **Concurrency**: the `MVar` serialises reads/updates against concurrent requests;
  maintenance is apply-after-commit so a crash mid-operation leaves the index
  rebuildable, never the source of truth.

## Compatibility Impact

- **Amends ADR-059**: adds an in-memory index for whole-tree queries while keeping
  the lazy per-folder live read. Does not supersede RFC-0026's tree contract.
- Internal only: move/delete/replay change *how* they find candidates, not their
  observable contract (same refusals, same rewrites). The pre-filtered scan path is
  retained.
- New config keys for the persisted index path and the rebuild endpoint; defaults
  preserve current behaviour.
- New `POST /index/rebuild` endpoint (operator/cron-facing); no other API change.
- No new MicroHs capability.

## Testing and Quality Gates

- `make check` and `make editor-check`.
- Server (hspec): the pure index -- build from a fixture page set yields the correct
  `outbound`/`inbound`; a per-page update (edit/add/remove links) patches the inverse
  correctly; referrer and move-rewrite-set queries match what `referrersMatching` /
  `planMoveRewrites` find over the same fixture (the index must agree with the scan);
  section subtree referrer queries; idempotent rebuild equals incremental result
  after a sequence of mutations (the anti-drift invariant).
- IO: build-from-tree over a `build/` fixture; maintenance hooks leave the index
  equal to a fresh rebuild after move/delete/restore/save/create.
- Performance: a regression check that a move/delete over a large fixture does not
  read every page once the index is warm (e.g. count reads, or assert latency bound).

## Rollout Plan

1. **Phase 1 -- Pure link-graph model.** A module with the index type, `build ::
   [(PagePath, Body)] -> Index`, `update :: PagePath -> Body -> Index -> Index`,
   `remove`/`relocate`, and `referrers`/`rewriteCandidates` queries. Reuses
   `DocumentLinks`. Exhaustively unit-tested against the scan's results.
2. **Phase 2 -- In-memory store + build-from-tree.** The `MVar`, build via the existing
   tree walk, and a thread-safe accessor. No behaviour change yet.
3. **Phase 3 -- Wire move/delete/replay to the index.** Replace the per-operation
   `enumerateRelevant` lookup with an index query (keeping the scan as build path and
   fallback). Measure the speedup.
4. **Phase 4 -- Incremental maintenance.** Save/create/move/delete/restore update the
   index; assert index == rebuild after each in tests.
5. **Phase 5 -- Persistence + rebuild trigger + cron.** Persist the index (startup
   cache, single writer); startup loads-then-background-rebuilds. A `POST /index/rebuild`
   endpoint rebuilds from the tree, swaps, re-persists, and logs drift; the periodic
   cron and the refresh workflow trigger it. Document the freshness contract.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or its design contracts do not cover,
  stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if
  another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user approval.

## Open Questions

- (Resolved) **Build timing / startup**: load the persisted copy for an instant
  start, then background-rebuild from the tree to self-correct.
- (Resolved) **Out-of-band staleness**: the navigation-tree consistency model
  (ADR-059) -- authoritative for in-server changes, out-of-band changes appear on the
  next rebuild -- bounded by a periodic cron-triggered rebuild. No per-operation
  fingerprint (no cheap mtime in mhs).
- (Resolved) **Persistence**: persisted as a startup cache; single writer (the
  server), so no reconciliation race.
- (Resolved) **Cron interval**: default **hourly** (bounds the out-of-band exposure
  window to <=1h at ~3.5s/run), operator-configurable.
- (Resolved) **Delete safety back-stop**: trust the index uniformly for move and
  delete; the per-delete authoritative scan is a documented dial, **off by default**,
  to be enabled only if the drift log shows real out-of-band drift. A wrong delete is
  bounded by the cron window and recoverable (target in trash, dangling link fixable).

## Implied Decision Records (to add on acceptance)

- **ADR-066**: Whole-tree link queries (move/delete referrers and rewrite sets) are
  served by an in-memory **link index** (resolved link graph + inverted referrer
  map), built from the document tree and maintained by in-server mutations; amends
  ADR-059, which deferred an index, while keeping the nav tree's lazy per-folder live
  read. The byte-prefiltered scan (RFC-0027) is its build path and correctness
  fallback.
- **ADR-067**: The index adopts the navigation-tree **consistency model** (ADR-059):
  authoritative for in-server changes, out-of-band changes appear on the next
  rebuild. The server is the **single writer**; a periodic cron *triggers* a
  server-side rebuild-from-tree (`POST /index/rebuild`) that re-persists and logs
  drift, bounding out-of-band staleness to the cron interval. No per-operation mtime
  fingerprint (mhs lacks cheap mtime; FFI `stat` not worth the portability cost).
- **ADR-068**: The index is persisted outside the document tree as a startup cache
  (loaded then background-rebuilt); single-writer makes this safe (no reconcile race).

## CONTEXT.md additions (on acceptance)

- **Link index**: the server's in-memory resolved `.md`->`.md` link graph of the
  **document tree** (each **page**'s outbound `.md` link targets and the inverted
  `tree path -> referring pages` map), consulted by **move** and delete to find
  referrers and rewrite sets without scanning every page. Authoritative for in-server
  changes; out-of-band changes appear on the next rebuild (the same freshness contract
  as the **navigation tree**, ADR-059). Not a search index (that is a separate future
  system) and carries no titles or asset edges.
