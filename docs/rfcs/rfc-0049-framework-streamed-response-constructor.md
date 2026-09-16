---
id: RFC-0049
name: Framework Streamed-Response Constructor
status: Draft
owners:
    - alistair
created: 2026-09-17
updated: 2026-09-17
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0013
    - RFC-0014
    - RFC-0040
design_contract_rfcs:
    - RFC-0043
---

# Framework Streamed-Response Constructor

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-17 |
| Started   |            |
| Completed |            |

## Summary

Serving a document as a sized, streamed response -- a prefix, a file streamed through a per-block
transform, and a suffix, behind an exact `Content-Length` from a pre-count pass -- is a framework
capability whose only implementation is in the wiki application. Move the construction into the
framework as one response constructor that owns the count and the missing-file cleanup, so the count
has a framework test (including its fault-injection path), and make one function the single place that
walks the response-body taxonomy for an egress stage, so the application and the middleware no longer
re-match it.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 4) found that `MicroHttp.Http` owns the `ResponseBody` type (`StrictBody`, `StreamBody`,
`SizedStreamBody`, `FileBody`) but the producers of a streamed body live in `MicroHttp.Stream`
(`transformedFileBody`, `transformedTempFileBody`), and the only party that joins a producer to a
`Response` is the application:

- `Verso.App.documentStreamedResponse` runs the `Content-Length` pre-count
  (`Stream.foldFileBlocks docBlockBytes addEscapedLength 0 fsPath` under `Exception.onException
  onMissing`), then builds `Http.SizedStreamBody total (producer ...)`. So the framework has no test of
  its own sized-stream count, and the count's missing-file path (the `onException` cleanup that removes
  a temp capture) is untested; the review named that gap twice.
- The body taxonomy is matched in three modules: `Http.writeResponse` (which must, to write it),
  `Http.serialiseResponse` (which rejects streams), and `Middleware.fuseBody` (which re-matches all
  four to fuse an egress stage, no-opping strict and file). Adding or changing a body kind touches each.

RFC-0040 gave the application the constant-space streamed document; this RFC moves the reusable part of
that construction down into the framework, now that its shape has stabilised.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it as complete in the
phase checklist.

## Goals

- One framework constructor builds a sized, streamed file response and owns the pre-count and the
  missing-file cleanup, with a framework test that asserts the `Content-Length` equals the bytes
  written and that a missing file is reported (and a temp removed) rather than served.
- One framework function (`mapBody`) is the single place an egress stage walks the body taxonomy;
  `Middleware.fuseBody` becomes a thin adapter and the application stops constructing `SizedStreamBody`
  by hand for the file case.
- No behaviour change on the wire: the same bytes, the same `Content-Length`, the same 404s.

## Non-Goals

- The chunked diff body (`Verso.App.diffStreamBody`) and the in-memory seed page
  (`documentBytesResponse`). The diff streams a bespoke row-scanning transform, not the block transform
  this constructor takes, and the seed page is a small in-memory value; both stay as they are and remain
  ordinary `StreamBody`/`SizedStreamBody` values that `mapBody` still handles for egress. A chunked
  file-response variant is deferred until a caller needs it (YAGNI).
- Changing the `sendfile` path or the `FileBody` zero-copy send. This RFC only records how the carried
  `FileBody` size is used (below); it does not change it.
- Folding `StrictBody`/`FileBody` construction (the framework's `Router`/`Static`/`Middleware` 404 and
  error responses) into a new constructor; they are already one-liners in the framework.

## Proposal

### The Sized Streamed-File Constructor

`MicroHttp.Http` gains a constructor that builds a sized streamed response from a file, a prefix and a
suffix, through a per-block transform. It lives in `Http` because `Http` owns `Response`/`ResponseBody`
and already imports `MicroHttp.Stream` (which owns the producers); `Stream` cannot build a `Response`
(it does not, and must not, import `Http`).

```haskell
-- The per-block operation of a sized streamed body: the block size, the transform applied to each
-- block of the file, and the byte length that transform produces (computed cheaply, without
-- allocating the transformed bytes, so the count pass stays constant-space).
data BlockTransform = BlockTransform
    { btBlockSize :: Int
    , btApply :: BS.ByteString -> IO BS.ByteString
    , btLength :: BS.ByteString -> IO Int
    }

-- Build a sized response: prefix, the file streamed through the transform, suffix, behind an exact
-- Content-Length summed from the prefix and suffix lengths and the transform's per-block length. A
-- Left is returned when the file cannot be read for the count (it vanished), so the caller answers a
-- 404; the head is never written for a Left.
transformedFileResponse
    :: Status -> Headers
    -> BS.ByteString          -- prefix (already includes any doctype the caller wants)
    -> BlockTransform
    -> FilePath
    -> BS.ByteString          -- suffix
    -> IO (Either Stream.StreamError Response)

-- As above for a temporary capture served once: the streaming body removes the file when it finishes
-- or the consumer stops, and a count failure removes it before the Left.
transformedTempFileResponse
    :: Status -> Headers -> BS.ByteString -> BlockTransform -> FilePath -> BS.ByteString
    -> IO (Either Stream.StreamError Response)
```

The constructor runs `Stream.foldFileBlocks (btBlockSize t) (\n b -> (n +) <$> btLength t b) 0 path`
for the count under the same `onException` cleanup the application has today, and on success builds
`SizedStreamBody total (Stream.transformedFileBody (btBlockSize t) prefix (btApply t) path suffix)`.
The `btLength`/`btApply` pair keeps the current efficiency: the count sums the transformed lengths
without allocating the transformed bytes (`Html.escapedLength` today), and the body allocates them once
as it streams (`Html.escapeBlockBytes`). Their agreement -- that `btLength b == BS.length =<< btApply b`
-- is the invariant the framework test pins by asserting the response's `Content-Length` equals the
bytes an in-memory sink receives.

`Verso.App` keeps only what is document-specific. `documentFileResponse` and `documentTempFileResponse`
become calls passing `BlockTransform docBlockBytes Html.escapeBlockBytes Html.escapedLength` and the
document's shell bytes, mapping a `Left` to `treeNotFound`. `documentStreamedResponse`, the local count
pass and its `onException` cleanup leave `App`.

### One Place Walks The Taxonomy

`MicroHttp.Http` gains:

```haskell
-- Transform the enumerator of a streaming body (sized or close-delimited), leaving a strict or file
-- body unchanged. The single place an egress stage rewrites a body; the taxonomy is matched here, not
-- in the middleware.
mapBody :: (Iteratee.Enumerator Stream.StreamError () -> Iteratee.Enumerator Stream.StreamError ())
        -> Response -> Response
```

`Middleware.fuseBody` becomes a thin adapter that builds the enumerator transform from its sink stage
and calls `Http.mapBody`, so `Middleware` no longer names `StrictBody`/`StreamBody`/`SizedStreamBody`/
`FileBody`. After this, the taxonomy is matched only inside `MicroHttp.Http` (`writeResponse`,
`serialiseResponse`, `mapBody`).

### The FileBody Size Is Advisory (ADR-0034 Amendment)

The review noted that `Server.socketSinkFile` re-opens and re-sizes the file and uses the size carried
on `FileBody` only for the access log, while ADR-0034's text says the sink "writes the head with the
carried size". The code (and the `Http.hs` comment on `ResponseSink`) is the truer statement: the sink
is authoritative and re-stats, so a `FileBody` whose file changed between construction and send still
gets a correct `Content-Length`; the carried size is advisory, for the access-log byte count. This RFC
amends ADR-0034 to record that as the decision, with no code change. Trusting the carried size and
dropping the re-stat is the alternative, rejected below.

### Key Decisions

- The constructor lives in `MicroHttp.Http`, the owner of `Response`, building on `Stream`'s producers.
- `BlockTransform` carries both the transform and a cheap length function, preserving RFC-0040's
  constant-space count; the framework does not re-derive the length by running the transform twice.
- The `FileBody` carried size stays advisory and the socket sink authoritative (ADR-0034 amended to
  match the code), because the re-stat guards against a file that changed after the body was built.

## Alternatives Considered

- A `Framing = Chunked | Sized` parameter and a chunked file variant, as the review sketched: no current
  file-backed caller streams a block transform without a `Content-Length` (the diff has its own
  transform), so the chunked variant is deferred until one appears.
- Trust the carried `FileBody` size in the socket sink and drop the re-stat: matches ADR-0034's letter
  and saves one `stat`, but serves a wrong `Content-Length` if the file changed between build and send;
  the safety of the re-stat is worth the syscall.
- Put the constructor in a new `MicroHttp.ResponseBody` module: `Http` already owns the type and is the
  natural home; a new module would split one concept.

## Security Impact

- None. The same bytes are served behind the same `Content-Length`.

## Reliability Impact

- The sized-stream count and its missing-file cleanup gain a framework test, including the
  fault-injection path (a file removed before the count) that the application code has never covered.
- Behaviour-preserving for every existing response; protected by the integration `AppSpec` (which
  exercises the document, read, revision-view and diff responses) and the new framework test.

## Compatibility Impact

- Internal framework interface additions and one middleware simplification; no wire, on-disk or
  configuration change. `ResponseBody`'s four constructors are unchanged.

## Testing and Quality Gates

- `make check` green before and after.
- A new `test/integration/MicroHttp/Http/ResponseFileSpec.hs` case (or an addition to it): a
  `transformedFileResponse` over a known file with an identity and a length-changing transform, driven
  through an in-memory sink, asserts the head's `Content-Length` equals the bytes received; a missing
  file yields a `Left` and, for the temp variant, removes the file.
- `MiddlewareSpec` continues to prove an egress stage rewrites a streaming body and passes a file body
  through, now via `mapBody`.

## Rollout Plan

Test-first; committed when green.

### Phase 1: The Constructor

1. Framework test for `transformedFileResponse`/`transformedTempFileResponse`: the `Content-Length`
   equals the bytes written; a missing file is a `Left`; the temp variant removes the file on failure.
2. `Http.BlockTransform`, `transformedFileResponse`, `transformedTempFileResponse` implemented over
   `Stream.foldFileBlocks`/`transformedFileBody`.
3. `Verso.App`'s `documentFileResponse`/`documentTempFileResponse` call them; `documentStreamedResponse`
   and its count pass are deleted.

### Phase 2: One Taxonomy Walk

1. `Http.mapBody` with a test; `Middleware.fuseBody` reduced to an adapter over it.

### Phase 3: Records

1. ADR-0034 amended (carried size advisory, sink authoritative); architecture page
   (`docs/architecture/streaming-algebra.md`) updated where it lists the body pipelines; RFC moved to
   `implemented/`; `bun run rfc:index`, `bun run adr:index`.

## Open Questions

- Should the in-memory seed page (`documentBytesResponse`) also route through the constructor for
  uniformity, or stay a direct `SizedStreamBody` over a strict enumerator? The proposal leaves it,
  because it is not file-backed and the constructor is about the file count; a reviewer may prefer one
  builder for every document response.
