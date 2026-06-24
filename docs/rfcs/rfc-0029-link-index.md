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

Add a server-side **link index** -- the corpus's resolved link graph, held in
memory: for each page its outbound `.md`/`assets` targets, and the inverse, a map
from each tree path to the pages that link to it. Move and delete consult the index
to find referrers and the files a move must rewrite, instead of reading and
link-parsing every `.md` on each operation. The index is built once (the cost a
single scan already pays), maintained incrementally by the in-server mutations that
already know what changed (save, create, move, delete, restore), and rebuilt to
absorb out-of-band changes (notably the periodic corpus refresh). Expected outcome:
move/delete drop from a whole-corpus scan to an index lookup (seconds to
milliseconds at the current ~3,900-page scale, and flat as the corpus grows), and
the same graph enables whole-tree search that the live-read tree (ADR-059) cannot.

## Context

RFC-0027's move and delete must find, across the **whole** tree, every page whose
relative links resolve to the target (delete's refuse-if-referenced; move's link
rewrite). With no index, each operation reads every `.md` and parses its links.
Measured on the reference corpus (~3,900 `.md` files, some link-dense and up to
~260 KB), parsing all of them took **~86 s** per operation -- so a delete appeared to
hang and the client never saw a response. RFC-0027 mitigated this with a byte
pre-filter (only unpack and parse files whose raw bytes contain the target's
slug/filename), bringing it to **~3.5 s**, now dominated by the unavoidable read of
every `.md`. That is acceptable today but grows linearly with the corpus, and every
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
corpus is **periodically re-exported from an authoritative source in its original
layout** (RFC-0028), and may be edited directly out-of-band. Any index is a derived
cache that must be rebuilt or reconciled after such changes; the design below treats
the index as exactly that -- a rebuildable cache, not a second source of truth.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it
as complete in the phase checklist.

## Goals

- A **resolved link graph** of the corpus: per page, its outbound in-tree `.md` and
  `assets/` targets (tree-absolute), built by reusing the RFC-0027 link engine
  (`MicroHttp.DocumentLinks`).
- An **inverted referrer map** (`tree path -> referring pages`) so move and delete
  answer "who links to X / into this subtree" by lookup, not by scanning.
- **In-memory** storage with a one-time build (lazy at first use, or at startup),
  held behind a single accessor so callers do not touch the filesystem to ask.
- **Incremental maintenance**: each in-server mutation (save, create, move, delete,
  restore) updates the index for exactly the pages it changed.
- **Rebuild** to absorb out-of-band changes (the corpus refresh, direct edits) --
  the index's analogue of the nav tree's explicit refresh (ADR-059).
- Move/delete/replay consult the index; the byte-prefiltered scan
  (`enumerateRelevant`) remains as the build path and a correctness fallback.
- (Optional, later) a **whole-tree search** endpoint over titles/paths, the
  capability ADR-059 traded away.

## Non-Goals

- **Persisting the index to disk.** v1 is in-memory, rebuilt on startup; persistence
  (and its own staleness story) is deferred (see Open Questions).
- **Replacing the nav tree's lazy live read.** Per-folder expansion stays a live
  `GET /tree` read (ADR-059); the index serves whole-tree queries (referrers,
  rewrite sets, search), not folder listing.
- **Full-text / content search.** The index covers structure (links, titles, paths),
  not page body text search or ranking.
- **A query language or external query API.** Internal lookups plus, later, one
  search endpoint.
- **Indexing non-link metadata** (sidecar contents, asset bytes) beyond what move's
  asset analysis already computes from the source folder.
- **Cross-process / multi-server coherence.** Single-process server; the index lives
  in that process.

## Proposal

### What is indexed

A pure value computed from the corpus:

- `outbound :: Map PagePath [TreePath]` -- each page's resolved in-tree link targets
  (the `.md` links and `assets/<name>` refs that `DocumentLinks.pageLinks` +
  `resolveTarget` already yield), tree-absolute.
- `inbound :: Map TreePath [PagePath]` -- the inverse: every page that links to a
  given tree path. This is the referrer map move/delete need.
- `titles :: Map PagePath Title` (optional, for search/labels) -- frontmatter `name`
  or humanised fallback, the same the nav tree computes.

`inbound` is derived from `outbound`; storing both lets a mutation update the inverse
without a full rebuild. Section-level questions ("who links into subtree S") are a
prefix query over `inbound` keys (S and its descendants), exactly the predicate
`referrersMatching` already encodes.

### Lookups the index serves

- **Delete refuse-if-referenced**: `inbound` for the target (page) or the subtree
  (section), minus the parent listing entry and, for a section, the subtree's own
  pages -- the existing `referrersMatching` semantics, now over the index instead of
  a fresh scan.
- **Move rewrite set**: the pages a move must rewrite are exactly the moved subtree's
  pages plus `inbound` of the moved paths -- the index returns the candidate set,
  then the existing `planMoveRewrites`/`planPageMove` compute the byte-precise edits
  on just those pages.
- **(Later) search**: substring/prefix over `titles`/paths.

The index narrows *which* pages to process; the pure engines
(`DocumentLinks`/`DocumentListing`) still compute the exact edits, so correctness is
unchanged and the index is a performance layer, not a second implementation.

### Storage and lifecycle

- The index lives in an `MVar` (or equivalent) created at server start, populated
  **lazily on first whole-tree query** (or eagerly at startup -- Open Questions),
  using the existing tree walk to read and parse every `.md` once.
- **Incremental maintenance**: the in-server mutations update the index for the
  pages they touch -- a save re-parses one page's outbound set and patches `inbound`;
  create adds a page; move/delete/restore relocate or remove entries (the same path
  remapping the link rewrite already computes). Maintenance runs after the
  filesystem mutation succeeds, so the index reflects committed state.
- **Out-of-band changes**: a corpus refresh or direct edit is not seen by
  incremental maintenance. The index is therefore **rebuildable on demand** (a
  rebuild trigger, e.g. extending the nav tree's existing refresh, or a dedicated
  endpoint), and a rebuild is cheap relative to its benefit (one scan ~= today's
  per-operation cost, paid once). This mirrors ADR-059's contract -- out-of-band
  changes appear on the next *rebuild* rather than the next read -- and is the
  explicit trade this RFC makes versus a never-stale live read.

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
- **Persist the index to disk.** Avoids the startup rebuild cost. Rejected for v1:
  it reintroduces exactly the persistence/staleness story ADR-059 warned about (a
  persisted index is stale the moment the corpus is re-exported), for a startup
  saving (~seconds) that is not the binding constraint. Revisit if startup grows.
- **Materialised index as the tree's source for listing too** (replace the live
  read). Rejected: ADR-059's reasoning still holds for per-folder expansion (cheap
  live, always correct, no drift); only whole-tree queries justify the index.
- **External search/index service.** Out of scope for a single-binary server with no
  external dependencies (RFC-0001 posture).
- **Index only titles/paths (search), not the link graph.** Rejected: it would not
  address the motivating move/delete cost, which is the link graph specifically.

## Security Impact

- The index holds only tree paths and titles derived from files already served; it
  exposes no new data. A future search endpoint returns paths/titles the client can
  already fetch, so it adds no disclosure surface beyond existing reads.
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
- **Build cost** is one whole-corpus scan (today's per-op cost) at startup/first use
  and per rebuild; bounded and observable (log build time/size).
- **Memory**: the graph is paths + small lists, not bodies -- order the count of
  links across the corpus (megabytes at the current scale), well within budget.
- **Concurrency**: the `MVar` serialises reads/updates against concurrent requests;
  maintenance is apply-after-commit so a crash mid-operation leaves the index
  rebuildable, never the source of truth.

## Compatibility Impact

- **Amends ADR-059**: adds an in-memory index for whole-tree queries while keeping
  the lazy per-folder live read. Does not supersede RFC-0026's tree contract.
- Internal only: move/delete/replay change *how* they find candidates, not their
  observable contract (same refusals, same rewrites). The pre-filtered scan path is
  retained.
- A new optional config key may gate eager-vs-lazy build or a future persistence
  path; defaults preserve current behaviour.
- No new MicroHs capability; no external API change. A later search endpoint is
  additive.

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
- Client (vitest), if the search phase lands: search result parsing/rendering.

## Rollout Plan

1. **Phase 1 -- Pure link-graph model.** A module with the index type, `build ::
   [(PagePath, Body)] -> Index`, `update :: PagePath -> Body -> Index -> Index`,
   `remove`/`relocate`, and `referrers`/`rewriteCandidates` queries. Reuses
   `DocumentLinks`. Exhaustively unit-tested against the scan's results.
2. **Phase 2 -- In-memory store + build-from-tree.** The `MVar`, lazy/eager build via
   the existing tree walk, and a thread-safe accessor. No behaviour change yet.
3. **Phase 3 -- Wire move/delete/replay to the index.** Replace the per-operation
   `enumerateRelevant` lookup with an index query (keeping the scan as build path and
   fallback). Measure the speedup.
4. **Phase 4 -- Incremental maintenance.** Save/create/move/delete/restore update the
   index; assert index == rebuild after each in tests.
5. **Phase 5 -- Rebuild trigger.** Absorb out-of-band changes (extend the nav tree
   refresh, or a dedicated endpoint); document the staleness contract.
6. **Phase 6 (optional) -- Whole-tree search.** A search endpoint over titles/paths
   and a client affordance; the capability ADR-059 deferred.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or its design contracts do not cover,
  stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if
  another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user approval.

## Open Questions

- **Build timing**: lazy (first whole-tree query pays the build) vs eager (at
  startup, so the first move/delete is already fast but startup is slower). Lean
  lazy, since startup should stay quick and many sessions never move/delete.
- **Out-of-band staleness handling**: a manual rebuild trigger only, vs cheap
  validation (e.g. directory mtimes, or a count/spot-check) that auto-invalidates.
  Lean manual rebuild for v1 (consistent with the nav tree's explicit refresh), with
  auto-validation as a later enhancement.
- **Delete safety back-stop**: should a delete verify "no referrers" against a fresh
  scan before destroying (paying the scan only on the rare delete), or trust the
  index? The refuse-if-referenced guard is the link-safety net, so a back-stop on
  delete (not move) may be worth the cost.
- **Persistence**: if startup/rebuild cost grows with the corpus, persist the index
  outside the corpus (same constraints as the operation log/trash) and reconcile on
  load. Deferred; revisit with measured growth.
- **Scope of search (Phase 6)**: titles + paths only, or also section/asset names?

## Implied Decision Records (to add on acceptance)

- **ADR-066**: Whole-tree link queries (move/delete referrers and rewrite sets) are
  served by an in-memory **link index** (resolved link graph + inverted referrer
  map), built from the corpus and maintained by in-server mutations; amends ADR-059,
  which deferred an index, while keeping the nav tree's lazy per-folder live read.
  Out-of-band changes are absorbed by rebuild, not assumed live.
- **ADR-067**: The link index is in-memory and rebuildable (not persisted) in v1;
  the byte-prefiltered scan (RFC-0027) is its build path and correctness fallback.

## CONTEXT.md additions (on acceptance)

- **Link index**: the server's in-memory resolved link graph of the corpus (per-page
  outbound targets and the inverted `tree path -> referring pages` map), consulted by
  move and delete to find referrers and rewrite sets without scanning every page;
  rebuilt to absorb out-of-band changes (amends the live-read **navigation tree**
  contract for whole-tree queries).
