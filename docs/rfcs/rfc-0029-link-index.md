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
| Started   | 2026-06-24       |
| Completed | 2026-06-24       |
| Revised   | 2026-06-26       |

## Revision (2026-06-26): freshness and persistence reversed

The design below was implemented (phases 1-5) and then **reverted from the move/delete
path**: on the real corpus the per-operation stat-fingerprint walk made operations
*slower* than the scan it replaced, and the whole-tree graph build is ~80-130 s of
`String` processing in the mhs interpreter (a lazy-build bug additionally made the first
operation appear to hang). The measured cost model is in
[link-index-performance.md](../design/link-index-performance.md).

Two load-bearing decisions are reversed in the revised design (the sections below are
annotated **(revised)** where they no longer hold):

- **Freshness is no longer a per-operation whole-tree stat check.** The running server
  *owns* the document tree (the only routine out-of-band writer is the periodic
  re-export, RFC-0028). So the index is built at startup, maintained incrementally for
  in-server mutations, and rebuilt on an **explicit refresh** after a re-export -- no
  per-operation walk, so an operation is the O(1) lookup. This accepts a bounded
  staleness window for *ad-hoc* on-disk edits between refreshes, which the original
  per-op check eliminated (ADR-067 is amended accordingly).
- **The index is persisted** (graph + fingerprint), reload-and-validated on startup, so
  the build is a one-off rather than paid on every restart. Persistence was an original
  Non-Goal; it is now in scope.

- **The link engine becomes ByteString-native** so the build (and the scan) stop paying
  the `String` conversion of every body.

## Summary

Add a server-side **link index** -- the document tree's resolved `.md`->`.md` link
graph, held in memory: for each **page** its outbound `.md` link targets, and the
inverse, a map from each tree path to the pages that link to it. Move and delete
consult the index to find referrers and the files a move must rewrite, instead of
reading and link-parsing every `.md` on each operation. The index is kept correct by
a **per-operation freshness check**: alongside the graph the server holds a
fingerprint of every `.md`'s `(path, mtime, size)`; before a move/delete it re-stats
the tree, and if the fingerprint is unchanged it trusts the index, otherwise it
rebuilds first. In-server mutations update the graph and the fingerprint together, so
they never look like drift. Expected outcome: move/delete drop from a whole-tree
read-and-parse to a cheap stat check plus an index lookup, while the index stays
**always correct** -- it never serves a stale answer on the correctness-critical
path, preserving ADR-059's guarantee rather than weakening it.

## Context

RFC-0027's move and delete must find, across the **whole** tree, every page whose
relative links resolve to the target (delete's refuse-if-referenced; move's link
rewrite). With no index, each operation reads every `.md` and parses its links.
Measured on the reference document tree (~3,900 `.md` files, some link-dense and up
to ~260 KB), parsing all of them took **~86 s** per operation -- so a delete appeared
to hang and the client never saw a response. RFC-0027 mitigated this with a byte
pre-filter (only unpack and parse files whose raw bytes contain the target's
slug/filename), bringing it to **~3.5 s**, now dominated by the unavoidable read of
every `.md`. That is acceptable today but grows linearly with the document tree, and
every move/delete pays it.

ADR-059 (RFC-0026) deliberately chose a **live filesystem read with no cached
index**, reasoning that the tree is the source of truth, is edited out-of-band, and
that a materialised index is a cache that drifts and needs a
persistence/reconciliation story. Two things have changed: (1) RFC-0027 added
whole-tree operations whose cost ADR-059 did not weigh (it considered only per-folder
expansion, which stays cheap), and (2) the read-everything floor is now the binding
constraint on those operations. RFC-0026 anticipated an index would be "its own RFC".
This is that RFC. It **amends** ADR-059 for whole-tree queries while keeping the nav
tree's lazy per-folder live read unchanged.

The drift concern ADR-059 raised is the crux, and this design answers it head-on
rather than living with it: the served document tree is **periodically re-exported
from an authoritative source in its original layout** (RFC-0028) and may be edited
directly out-of-band, so the server **detects** such changes (a stat-based
fingerprint) and rebuilds the index before relying on it. The index therefore stays a
derived cache that is *provably consistent with the filesystem at operation time*,
not a second source of truth and not a cache that can silently drift.

This requires a primitive mhs does not expose: a cheap file modification time
(`System.Directory` has no `getModificationTime`; `fileSizeBytes` cheats with
`lseek`). The design adds an **FFI `stat(2)`** binding, **macOS-first** -- the
`struct stat` layout is platform-specific, and cross-platform support is punted to
the separate portability RFC. This is a deliberate, scoped dependency: it is what lets
the index be fast *and* always correct, collapsing the otherwise-needed persistence,
cron, and operational-rebuild machinery.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it
as complete in the phase checklist.

## Goals

- A **resolved `.md`->`.md` link graph** of the document tree: per page, its outbound
  in-tree `.md` link targets (tree-absolute), built by reusing the RFC-0027 link
  engine (`MicroHttp.DocumentLinks`). Not asset edges (asset analysis is folder-local).
- An **inverted referrer map** (`tree path -> referring pages`) so move and delete
  answer "who links to X / into this subtree" by lookup, not by scanning.
- A **stat-based freshness fingerprint** (`path -> (mtime, size)` over every `.md`)
  held with the graph, so the server can cheaply detect out-of-band change.
- **Always correct on the critical path**: before a move/delete, re-stat the tree;
  trust the index when the fingerprint matches, rebuild first when it does not. The
  index never serves a stale referrer/rewrite answer (preserves ADR-059's
  always-correct property; no staleness window).
- **Incremental maintenance**: each in-server mutation (save, create, move, delete,
  restore) updates the graph *and* the fingerprint for exactly the pages it wrote, so
  in-server changes are never mistaken for out-of-band drift.
- Move/delete consult the index; the byte-prefiltered scan (`enumerateRelevant`)
  remains the build/rebuild path and the cold-index fallback.

## Non-Goals

- ~~**Persistence.**~~ **(revised)** The index is now persisted (graph + fingerprint)
  and reload-and-validated on startup, so the build is a one-off rather than paid on
  every restart. The original in-memory-only stance assumed the build was cheap; it is
  not (~80-130 s) until the ByteString engine lands, so persistence earns its keep.
- ~~**A periodic rebuild cron, a rebuild endpoint, or an operational "rebuild after
  edits" contract.**~~ **(revised)** There is now an **explicit refresh** (a rebuild
  trigger) invoked after the periodic re-export, since freshness is no longer checked
  per operation. Still no *cron* -- the refresh is event-driven (the re-export signals
  it), not scheduled.
- **Search of any kind.** Whole-tree/full-text/semantic search is a separate, future
  system (an embedding-vector + full-text store), not this link graph. No titles, no
  body text.
- **Replacing the nav tree's lazy live read.** Per-folder expansion stays a live
  `GET /tree` read (ADR-059); the index serves only the whole-tree link queries.
- **Asset edges / non-link metadata.** Asset ownership (exclusive/shared) is settled
  folder-locally and needs no whole-tree index.
- **Cross-platform `stat`.** macOS-first; other platforms are the portability RFC's
  concern. The binding is isolated so that RFC can extend it.
- **Cross-process / multi-server coherence.** Single-process server; the index lives
  in that process.

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
`referrersMatching` already encodes. The index carries no titles.

### Freshness: the stat fingerprint

> **(revised 2026-06-26)** The per-operation stat-fingerprint check below is *not* in
> the revised design: it was the dominant per-op cost (a whole-tree walk, twice per
> operation) and made operations slower than the scan. Freshness is now handled off the
> request path -- build at startup, maintain incrementally for in-server mutations,
> rebuild on an explicit refresh after a re-export -- because the server owns the tree
> (no ad-hoc out-of-band writers). The fingerprint is retained only to *validate a
> persisted index* on load. See [link-index-performance.md](../design/link-index-performance.md)
> and ADR-067 (amended).

Held alongside the graph is a **fingerprint** of the tree the graph was built from:
each `.md`'s `(tree path, mtime, size)`. `mtime` uses sub-second precision
(macOS `st_mtimespec`), so even an *equal-length* edit -- swapping one link target for
another of the same length -- moves the mtime and is detected; size alone could not
catch that.

Before a correctness-critical operation (move/delete) the server **re-stats every
`.md`** and compares to the stored fingerprint:

- **Match** -> the graph is provably consistent with the filesystem; serve the lookup
  in O(1).
- **Mismatch** -> an out-of-band change happened; **rebuild** the graph and
  fingerprint from the tree, then run the operation against the fresh index. The one
  operation that discovers the drift pays the rebuild; subsequent ones are fast again.

The per-operation cost is therefore O(files) `stat` calls (metadata only -- far
cheaper than the ~3.5 s read-and-parse) plus an O(1) lookup, with a full rebuild only
when the tree actually changed out-of-band. This is the deliberate trade: not the
O(1)-flat-with-growth a never-checked cache would give, but **sound** -- the index
cannot serve a stale answer.

### Lookups the index serves

- **Delete refuse-if-referenced**: `inbound` for the target (page) or the subtree
  (section), minus the parent listing entry and, for a section, the subtree's own
  pages -- the existing `referrersMatching` semantics, now over the index instead of a
  fresh scan.
- **Move rewrite set**: the pages a move must rewrite are exactly the moved subtree's
  pages plus `inbound` of the moved paths -- the index returns the candidate set, then
  the existing `planMoveRewrites`/`planPageMove` compute the byte-precise edits on just
  those pages.

The index narrows *which* pages to process; the pure engines
(`DocumentLinks`/`DocumentListing`) still compute the exact edits, so correctness is
unchanged and the index is a performance layer, not a second implementation.

### Storage and lifecycle

- The graph and its fingerprint live in an `MVar` (or equivalent), built **lazily on
  the first move/delete** (startup stays instant; many sessions never move/delete).
  Build = the existing tree walk (read + parse into the graph) plus a `stat` pass for
  the fingerprint.
- **Incremental maintenance**: after a mutation, the index is updated for **every page
  the operation wrote** -- not just the moved/deleted item. A move rewrites links in
  its referrers and (for a section) its subtree pages, changing *their* `outbound`
  too; the operation already computes that whole write-set (the rewrite plan), so
  maintenance re-derives `outbound` from the **new** bytes for each page in it, patches
  `inbound`, **and updates the fingerprint** for those files (re-stat them). Because
  the fingerprint is updated in lockstep, an in-server mutation does not make the next
  operation see false drift. The **index == full-rebuild** invariant (asserted in
  tests after mutation sequences) is the anti-drift gate.
- **Out-of-band changes** (the document-tree refresh, a direct edit) update neither
  graph nor fingerprint, so the next move/delete's stat check detects the mismatch and
  rebuilds. No schedule, no operator contract: drift is caught exactly when it would
  matter.
- **`replay-tool`** (RFC-0028) is a separate process with no warm index; it keeps
  using the byte-prefiltered scan directly. The index accelerates the running server's
  move/delete only.

### Relationship to RFC-0027's byte pre-filter

`enumerateRelevant` (RFC-0027) stays: it is the index's build/rebuild path (read +
filter + parse), the cold-index fallback (before the first build), and what
`replay-tool` uses. Move/delete in the server consult the index (after the fingerprint
check); everything shares `DocumentLinks`, so the index and the scan cannot diverge in
how a link resolves.

### Boundaries

- A new **pure module** owns the index type and its update functions (build from
  `[(PagePath, body)]`, apply a per-page change, query referrers/rewrite-set), unit-
  tested without IO.
- A small **FFI `stat`** binding (macOS) exposes `(mtime, size)` for a path; the
  fingerprint build/compare is a thin pass over the tree walk. Isolated so the
  portability RFC can extend it to other platforms.
- A thin **IO layer** owns the `MVar`, the build-from-tree, the per-operation
  fingerprint check, and the maintenance hooks the mutation handlers call.

## Alternatives Considered

- **Keep the byte-prefiltered scan only (RFC-0027 status quo).** Simplest, no
  index/maintenance, correct. Rejected as the *end* state: it reads every `.md` on
  every move/delete (~3.5 s, linear growth). Retained as the build/rebuild path,
  cold-index fallback, and `replay-tool`'s mechanism.
- **Trust an index with periodic (cron) rebuild and persistence, no per-op check.**
  This was the prior shape of this RFC. Rejected once a cheap mtime became available:
  it leaves a bounded *staleness window* (an out-of-band edit between cron runs can
  cause a wrong delete / dangling link), needs an operational rebuild contract, a
  persisted-cache format, a rebuild endpoint, and single-writer coordination. The
  per-operation fingerprint removes the window and all of that machinery, and is
  *always correct* rather than eventually correct.
- **Size+path-only fingerprint (no mtime).** Feasible without FFI, but **unsound**: an
  equal-length link swap changes neither path nor size, so a stale index would be
  trusted. Rejected -- defeats the soundness that justifies trusting the index.
- **Persist the index to disk.** Saves a build on restart. Rejected for v1: it adds a
  serialise/validate path for a ~3.5 s saving on an infrequent event; the lazy
  build-on-first-use keeps startup instant without it.
- **Materialised index as the tree's source for listing too.** Rejected: ADR-059's
  reasoning still holds for per-folder expansion (cheap live, always correct); only
  whole-tree queries justify the index.
- **A search index instead** (titles/text). Rejected: does not address the move/delete
  cost (the link graph), and search is a separate future system.

## Security Impact

- The index holds only tree paths derived from files already served; it exposes no new
  data and adds no disclosure surface beyond existing reads.
- All paths entering the index come from the validated tree walk
  (`resolveStaticPath`/`safeComponent`); the index is read-derived, no new write
  surface. The `stat` binding is called only on those validated paths.
- Inherits the server's current no-auth posture unchanged.

## Reliability Impact

- **Staleness ceases to be a correctness risk.** The per-operation fingerprint check
  means a stale graph is detected and rebuilt before a move/delete relies on it, so the
  link-integrity guarantee (no dangling links, no wrong delete) holds even under
  out-of-band edits -- the property a cron-bounded cache could only approximate.
- **Build cost** is one whole-tree scan, paid lazily on first use and on detected
  drift; bounded and observable (log build time/size and "rebuilt due to drift").
- **Per-operation cost** is O(files) `stat` calls; a perf risk to validate
  (Phase 2/3): if statting the whole tree per op is itself significant at scale, a
  debounce or directory-level pre-check is a fallback (recorded in Open Questions).
- **Memory**: the graph plus the fingerprint is paths + small tuples/lists, not bodies
  -- order the count of links/files (megabytes at the current scale).
- **Concurrency**: the `MVar` serialises reads/updates and the rebuild swap;
  maintenance is apply-after-commit, and a rebuild always reads the tree, so a crash
  mid-operation leaves the index rebuildable, never the source of truth. Re-deriving a
  page's `outbound` is idempotent, so an in-server update racing a rebuild is safe.

## Compatibility Impact

- **Amends ADR-059**: adds an in-memory index for whole-tree queries while keeping the
  lazy per-folder live read, and *preserves* ADR-059's always-correct property via the
  fingerprint check.
- Internal only: move/delete change *how* they find candidates, not their observable
  contract (same refusals, same rewrites). The scan path is retained.
- **Adds an FFI `stat(2)` binding, macOS-only** -- a new platform dependency tracked by
  the portability RFC. No other new MicroHs capability.
- No new endpoints, no new config keys, no persisted artefacts.

## Testing and Quality Gates

- `make check` and `make editor-check`.
- Server (hspec): the pure index -- build from a fixture page set yields the correct
  `outbound`/`inbound`; a per-page update (edit/add/remove links) patches the inverse
  correctly; referrer and move-rewrite-set queries match what `referrersMatching` /
  `planMoveRewrites` find over the same fixture (the index must agree with the scan);
  section subtree referrer queries; idempotent rebuild equals incremental result after
  a sequence of mutations (the anti-drift invariant).
- Freshness (IO, `build/` fixture): an out-of-band edit (write a file directly,
  including an *equal-length* link swap) is detected by the fingerprint and triggers a
  rebuild before the next move/delete, which then behaves correctly; an in-server
  mutation does **not** trigger a false-drift rebuild (fingerprint updated in lockstep).
- The `stat` binding: returns `(mtime, size)` with sub-second `mtime`, and a content
  edit moves the `mtime`.
- Performance: a move/delete over a large warm-index fixture does not read every page
  (count reads / assert a latency bound); and the per-op `stat` pass stays cheap.

## Rollout Plan

1. **Phase 1 -- Pure link-graph model.** A module with the index type, `build ::
   [(PagePath, Body)] -> Index`, `update`/`remove`/`relocate`, and
   `referrers`/`rewriteCandidates` queries. Reuses `DocumentLinks`. Unit-tested against
   the scan's results.
2. **Phase 2 -- FFI `stat` (macOS) + fingerprint.** The `(mtime, size)` binding and a
   `fingerprint :: tree -> Map path (mtime, size)` build/compare over the tree walk.
   Tested (sub-second mtime; content edit moves mtime).
3. **Phase 3 -- In-memory store + build-from-tree + freshness check.** The `MVar`
   holding graph + fingerprint, lazy build, the per-operation stat-check-then-trust-or-
   rebuild path, and a thread-safe accessor. No behaviour change to move/delete yet.
4. **Phase 4 -- Wire move/delete to the index.** Replace their `enumerateRelevant`
   lookup with the freshness-checked index query (scan stays the rebuild path,
   cold-index fallback, and `replay-tool`'s mechanism). Measure the speedup.
5. **Phase 5 -- Incremental maintenance.** Save/create/move/delete/restore update graph
   and fingerprint for their write-set; assert index == rebuild and no-false-drift after
   each in tests.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or its design contracts do not cover,
  stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if
  another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user approval.

## Open Questions

- (Resolved) **Freshness mechanism**: a per-operation `(path, mtime, size)` fingerprint
  with rebuild-on-detected-drift; always correct, no window, no cron, no persistence,
  no back-stop dial.
- (Resolved) **Build timing**: lazy on the first move/delete; no persisted cache.
- (Resolved) **Data model**: the `.md`->`.md` link graph only (no assets, no titles).
- (Resolved) **Per-operation `stat` cost at scale**: measured in Phase 2 on a synthetic
  4,000-`.md` tree -- a single fingerprint pass (walk + 4,000 `stat`s) is ~0.25-0.3 s
  warm (two passes ~0.57 s), versus the ~3.5 s read-and-parse it replaces (~10x cheaper)
  and well within response time. No debounce needed at the current scale. Should the
  tree grow much larger, the recorded fallback is a short-TTL fingerprint debounce
  (accepting a tiny window) or a coarser directory-level pre-check.
- (Resolved) **End-to-end speedup (Phase 4)**: on a synthetic 4,000-`.md`, 78 MB
  link-dense tree (~20 KB bodies, like the real corpus's large pages), the page
  enumeration a move/delete pays dropped from **~10.3 s/op** (scan: read + unpack every
  matching body) to **~0.28 s/op** (warm index: a `stat` fingerprint pass plus reading
  only the candidate set) -- roughly **36x**. The advantage is body-size-dependent: on
  tiny bodies a `stat` costs about as much as a read, so the index's win is small to nil
  there; it is large exactly where it matters, the read-dominated large-page corpus.
- **`stat` granularity portability**: macOS gives sub-second `st_mtimespec`; the
  portability RFC must confirm the equivalent on other platforms (and that the
  equal-length-edit soundness argument holds there).

## Implied Decision Records (to add on acceptance)

- **ADR-066**: Whole-tree link queries (move/delete referrers and rewrite sets) are
  served by an in-memory **link index** (resolved `.md`->`.md` link graph + inverted
  referrer map), built from the document tree and maintained by in-server mutations;
  amends ADR-059, which deferred an index, while keeping the nav tree's lazy per-folder
  live read. The byte-prefiltered scan (RFC-0027) is its build path, cold-index
  fallback, and `replay-tool`'s mechanism.
- **ADR-067**: The index is kept correct by a **per-operation stat fingerprint**
  (`path, mtime, size` over every `.md`): a move/delete re-stats the tree and trusts the
  index only when the fingerprint matches, else rebuilds first. This **preserves**
  ADR-059's always-correct property (no staleness window) and removes the cron,
  persistence, operational-rebuild contract, and delete back-stop a never-checked cache
  would require. It depends on an **FFI `stat(2)` binding, macOS-first**; cross-platform
  support is deferred to the portability RFC.

## CONTEXT.md additions (on acceptance)

- **Link index**: the server's in-memory resolved `.md`->`.md` link graph of the
  **document tree** (each **page**'s outbound `.md` link targets and the inverted
  `tree path -> referring pages` map), consulted by **move** and delete to find
  referrers and rewrite sets without scanning every page. Kept correct by a
  per-operation freshness check -- a `(path, mtime, size)` fingerprint of every `.md`;
  an operation re-stats the tree and rebuilds the index if it changed out-of-band --
  so it never serves a stale answer (preserving the **navigation tree**'s
  always-correct contract, ADR-059). Not a search index (a separate future system);
  carries no titles or asset edges.
