---
id: ADR-0067
name: The Link Index Is Kept Correct by a Per-Operation Stat Fingerprint
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0028]
---

# ADR-0067: The Link Index Is Kept Correct by a Per-Operation Stat Fingerprint

> Status: **Amended (2026-06-26)**. The per-operation stat-fingerprint check was implemented and then reverted: on
> the reference corpus it was the dominant per-op cost (a whole-tree walk, run twice per operation) and made
> move/delete *slower* than the scan, while the graph build is ~80-130 s of `String` processing in mhs
> (`docs/rfcs/refs/link-index-performance.md`). Revised decision: the running server **owns** the document tree --
> the only routine out-of-band writer is the periodic re-export (RFC-0028) -- so freshness is handled **off the
> request path**: the index is built at startup, **persisted** (graph + fingerprint) and reload-and-validated on
> restart, maintained **incrementally** for in-server mutations, and rebuilt on an **explicit refresh** invoked
> after a re-export. An operation is then the O(1) lookup with no walk. This accepts a bounded staleness window
> for *ad-hoc* on-disk edits between refreshes (the original per-op check eliminated that, at a cost that proved
> too high); it does not apply to in-server edits, which are maintained in lockstep. The FFI `stat` binding is
> retained -- now to fingerprint the tree for **validating the persisted index on load** and for the explicit
> rebuild, rather than per operation. The link engine is also made ByteString-native so the build stops paying the
> per-body `String` conversion. The original per-operation design is recorded below for history.

## Context

ADR-0059's drift concern is the crux of caching the tree: the served corpus
is periodically re-exported from an authoritative source and may be edited
out-of-band, so a materialised index can silently disagree with the filesystem. A
cron-bounded rebuild leaves a staleness window in which a move/delete relies on a
stale graph (a wrong delete, a dangling link).

## Decision

the index is kept correct by a **per-operation stat fingerprint** -- a
`(path, mtime, size)` tuple over every `.md`, held alongside the graph. Before a
move/delete the server re-stats the tree and compares: a match means the graph is
provably consistent with the filesystem (serve the O(1) lookup); a mismatch means an
out-of-band change happened (rebuild the graph and fingerprint, then run the
operation against the fresh index). `mtime` uses sub-second precision (macOS
`st_mtimespec`) so an equal-length link swap is still detected. In-server mutations
update the graph *and* the fingerprint in lockstep, so they never look like drift.
This **preserves** ADR-0059's always-correct property (no staleness window) and removes
the cron, persistence, operational-rebuild contract, and delete back-stop a
never-checked cache would require. It depends on an **FFI `stat(2)` binding,
macOS-first** (mhs's `System.Directory` exposes no modification time); cross-platform
support is deferred to the portability RFC, with the binding kept isolated so that RFC
can extend it.

## Consequences

each operation pays O(files) `stat` calls (metadata only, far cheaper
than the ~3.5 s read-and-parse) plus an O(1) lookup, with a full rebuild only on
detected out-of-band drift. Staleness ceases to be a correctness risk. The per-op
`stat` cost at scale is validated empirically (RFC-0029 Open Questions); if it is
itself significant, a short-TTL fingerprint debounce is the recorded fallback.
