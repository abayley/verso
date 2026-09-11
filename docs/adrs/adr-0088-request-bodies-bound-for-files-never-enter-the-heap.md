---
id: ADR-0088
name: Request bodies bound for files never enter the heap
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-11
updated: 2026-09-11
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0040]
---

# ADR-0088: Request bodies bound for files never enter the heap

## Context

The asset upload handler read its body with `Iteratee.readBodyStrict`, then wrote the resulting
`ByteString` to disk and, on a name collision, read the existing file whole to compare. Under MicroHs a
`ByteString` payload is `malloc`'d outside the cell arena, so it does not count toward the pressure that
triggers a collection: intermediates are garbage immediately, but nothing prompts the collector to reclaim
them. RFC-0040's baseline measured a single 10 MiB upload at ~560MB of transient resident memory (about
56x the body, the `foldr append` fold over ~2,560 socket chunks), and four concurrent uploads took the
server past 25GB and exhausted the host. Neither RFC-0039 safety net applied: the tight arena is bypassed
and `heap exhausted` never fires. That is a denial-of-service lever available to any client allowed to
upload, and a body cap cannot close it, because the cost is per request and grows under concurrency.

## Decision

A request body whose destination is a file is streamed to that destination and never materialised as a
value. The framework provides `Stream.fileSinkI`, which writes each chunk to a file reserved beside the
final location (`FileSystem.reserveTempFile`), enforces the caller's byte cap before every write, and on
any failure removes the partial file; the handler then renames the complete file into place. Whole-file
equality, wherever a handler needs it, is `Stream.filesEqual`: a size check by `stat`, then a 64KB
block-at-a-time comparison. `Iteratee.readBodyStrict` remains for bodies that must be values, and those
callers keep caps small enough that the fold is not the cost.

## Why

- Measured on the real corpus at the 8,000,000-cell default: a 10 MiB upload took 5.57s with resident
  memory peaking 560MB above baseline before; 1.03s and 11MB above baseline after, with the stored bytes
  identical and no temp file left on any path (RFC-0040 baseline ref, phase 3 outcome).
- The body arrives as ~4KB socket chunks and its only destination is a file, so holding it as a value
  buys nothing and costs a fold that is O(total x pieces) in MicroHs.
- The temp file lives in the target directory so the final rename is atomic and never crosses a
  filesystem; the cap is checked ahead of the write so an over-cap body leaves at most `limit` bytes on
  disk and then nothing.
- The refusal paths still consume the body through a discard sink, so a rejected upload leaves nothing
  unread on the connection, exactly as the strict read did.

## Reopens when

A body destination appears that is neither a file nor small enough to hold as a value -- for instance a
body that must be transformed before it is stored -- at which point the sink needs a transforming stage
rather than a bypass back to a strict read.

## Consequences

Handlers that accept uploads follow this shape rather than reading the body first. The bounded
concurrency measurement RFC-0040 deferred from its phase 1 can now be taken safely, because the expected
per-request cost is a fixed buffer. The framework's `Stream` module owns both the sink and the comparison,
alongside the file producers it already had.
