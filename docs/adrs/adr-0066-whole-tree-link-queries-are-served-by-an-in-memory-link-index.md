---
id: ADR-0066
name: Whole-Tree Link Queries Are Served by an In-Memory Link Index
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0029]
---

# ADR-0066: Whole-Tree Link Queries Are Served by an In-Memory Link Index

> Status: Accepted (RFC-0029).

## Context

RFC-0027's move and delete must find, across the whole tree, every page
whose relative links resolve to the target (delete's refuse-if-referenced; move's
link rewrite). ADR-0059 deferred any index, so each operation reads and link-parses
every `.md` -- a byte pre-filter brought this to ~3.5 s on the reference corpus, but
that floor grows linearly and every move/delete pays it.

## Decision

whole-tree link queries are served by an in-memory **link index** -- the
document tree's resolved `.md`->`.md` link graph (each **page**'s outbound in-tree
`.md` link targets and the inverted `tree path -> referring pages` map), built from
the tree by reusing the RFC-0027 link engine (`MicroHttp.DocumentLinks`) and
maintained by in-server mutations. It carries no asset edges (asset ownership is a
folder-local question, ADR-0062, so a same-folder asset ref never crosses a moved or
deleted subtree boundary) and no titles (search is a separate future system). This
**amends ADR-0059**, which deferred an index, while keeping the navigation tree's lazy
per-folder live read unchanged. The byte-prefiltered scan
(`TreeMove.enumerateRelevant`) is retained as the index's build/rebuild path, its
cold-index fallback, and `replay-tool`'s mechanism, so the index and the scan cannot
diverge in how a link resolves.

## Consequences

move and delete change *how* they find candidates, not their observable
contract (same refusals, same rewrites). The index narrows *which* pages to process;
the pure engines (`planMoveRewrites`/`referrersMatching`) still compute the exact
edits, so it is a performance layer, not a second implementation. Single-process;
**persisted** to disk and reload-validated on startup (see ADR-0067 as amended -- the
original "in-memory only" stance was reversed once the build proved expensive).

A section move's candidate set (`rewriteCandidates`) was later tightened (2026-06-27) to the
pages whose links *cross the subtree boundary* -- subtree pages linking out plus outside
pages linking in -- rather than every subtree page, since a page linking only within the
moved subtree needs no rewrite. Still a superset of what `planMoveRewrites` changes, so the
observable contract is unchanged; it avoids reading/parsing the (often many) internal-only
subtree pages. With a direct `relocateIndex` (the inverse map is the old one re-keyed and
re-sorted, not rebuilt edge-by-edge), a large-folder move dropped ~6.6 s -> ~1.5 s on the
reference corpus (see `docs/design/link-index-performance.md`).
