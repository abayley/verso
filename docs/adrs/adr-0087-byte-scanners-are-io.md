---
id: ADR-0087
name: Byte scanners are IO; no unsafePerformIO in production code
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-10
updated: 2026-09-10
supersedes: [ADR-0086]
superseded_by: null
related_rfcs: [RFC-0029, RFC-0039]
---

# ADR-0087: Byte scanners are IO; no unsafePerformIO in production code

## Context

ADR-0086 sanctioned one `unsafePerformIO` shape: a deterministic, read-only foreign call (`memchr`) over a
private copy of a `ByteString`, so that the link scanner (`Verso.DocumentLinks`) and the line splitter
(`Verso.SearchChunks.lineRanges`) could stay pure for their pure callers. Its stated reason was to avoid
either turning those callers into `IO` or keeping a second, pure scanner in step with the first.

RFC-0039 changed the callers. The link index now scans each page as a stream inside `IO`; the move rewrite
streams pages inside `IO`; the planners take links rather than bodies, so they no longer scan at all. What
remained pure were three small sites: `LinkIndex.updatePage`'s body form (used only by tests and a bench),
two single-line scans in `Verso.DocumentListing` whose only callers run in `IO`, and the frontmatter and
search-chunk line splitting, whose production callers also run in `IO`. The purity the exception bought was
no longer load-bearing, while the exception itself still required a comment-enforced set of four invariants
and an allowlisted lint gate to keep it from spreading.

## Decision

Foreign calls are `IO`, and production code does not use `unsafePerformIO`. `DocumentLinks.pageLinks`,
`scanStep`, `scanChunk`, `scanChunks` and `scanFinish`, `SearchChunks.lineRanges` and `chunkPage`, and
`Frontmatter.leadingBlock` and `slice` return in `IO`. Code that needs links or line ranges from bytes calls
them from `IO`; code that only needs to reason about links (the move planners, `LinkIndex.updatePageLinks`,
`referrersMatching`, `assetNamesIn`) takes the links as data and stays pure. The lint target rejects any
import of `System.IO.Unsafe` under `packages/*/src`, with no allowlist.

## Why

A foreign call is an effect, and `IO` is the honest type for it; ADR-0086's argument for hiding that was the
cost to pure callers, and after RFC-0039 those callers are gone or trivially `IO` already. Keeping the type
honest costs a `do` block in a handful of tests and two `IO` signatures in `DocumentListing`; keeping the
exception costs a set of invariants that nothing checks mechanically. Only `memchr` is affected, so the
performance case in ADR-0086 (RFC-0029: link parsing 85MB to 15MB, 35ms to 8ms per 73KB page) is untouched;
what changes is the type of the function that makes the call, not the call.

The frontmatter reader keeps `memchr` rather than a pure `BS.elemIndex` split because on MicroHs every
`ByteString` search unpacks its argument to a list (ADR-0086 records the cost model), so a pure line split
over a whole document would reintroduce the per-request unpack RFC-0039 removed. Its callers were `IO`
already, so it simply joins them.

## Reopens when

- MicroHs gains a native, C-backed `ByteString` search, making `memchr` unnecessary and the question moot.
- A pure caller appears whose cost of becoming `IO` outweighs a second scanner. None is expected: the
  scanners' consumers are file readers, stream consumers and request handlers.

## Consequences

ADR-0086 is superseded; its cost model for MicroHs `ByteString` scanning remains accurate and is still the
reason `memchr` is used. `LinkIndex.updatePage`, `pageTargets` and `buildIndex` (the body-taking forms) are
removed; tests and the bench build an index by scanning in `IO` and folding `updatePageLinks`. The RFC-0039
alternative "make the scanner IO and drop unsafePerformIO" is now the chosen design, and its note to that
effect is added there. The lint gate added for ADR-0086's allowlist becomes a plain prohibition.
