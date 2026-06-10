---
id: RFC-0004
name: Iteratee Streaming IO
status: Draft
owners:
    - alistair
created: 2026-06-10
updated: 2026-06-10
supersedes: []
superseded_by: null
---

# Iteratee Streaming IO

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-10       |
| Started   |                  |
| Completed |                  |

## Summary

Adopt the iteratee and enumerator model as the streaming foundation for
request and response bodies, so the server handles bodies of any size in
constant memory. Producers (the socket, files, strict values) are
enumerators; consumers (request framing, handlers, the socket writer) are
iteratees; stream transformations (length bounding, future decompression or
chunking) are enumeratees. The `Application` contract changes: handlers
receive a strict request head and consume the body as a stream, and
responses may carry a streaming body. Middleware keeps its
`Application -> Application` shape (ADR-015), with stream-touching
middleware implemented by lifting enumeratees onto the ingress or egress
pipeline.

## Context

RFC-0003 made request reading correct but strict: `frameRequest`
accumulates the whole request before parsing, so memory is proportional to
message size and large bodies are buffered twice (frame, then parse). The
response side is similar: apart from the file chunk loop, bodies are strict
values. The project direction discussion settled on the iteratee model
rather than WAI-style readers, for three reasons: residual input lives in
the consumer's result (`Done a residual`) and flows forward through monadic
bind, so chunk-boundary misalignment is solved inside the abstraction
without producer pushback; enumerators own resource acquisition and
release, making cleanup exception-safe by construction; and enumerators
return the consumer's final state, which is exactly what a future
keep-alive loop needs to seed the next request with the previous request's
residue.

Primary references: Oleg Kiselyov's iteratee material
(<https://okmij.org/ftp/Haskell/Iteratee/>), the iterIO package design
(<https://hackage.haskell.org/package/iterIO-0.2.2/docs/Data-IterIO.html>),
and Edward Yang's analysis of the model's hard corners
(<https://blog.ezyang.com/2012/01/why-iteratees-are-hard-to-understand/>).
iterIO's `Data.IterIO.Http` is prior art for an HTTP server on this
decomposition and is worth a skim for its body-draining and error choices;
none of its code is taken.

This remains within ADR-010: no external streaming library. The model is
implemented locally as plain data types and functions, compilable by both
MicroHs and GHC without extensions.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Request and response bodies of any size are handled in constant memory:
  bounded by chunk and header limits, never by message size.
- Handlers consume request bodies as streams and may produce streaming
  response bodies.
- Stream transformations compose: the Content-Length bound, and later
  decompression or chunked encoding, are enumeratees in a uniform pipeline.
- Middleware keeps the ADR-015 `Application -> Application` type, with a
  documented taxonomy for head-level, ingress, egress, and failure-handling
  middleware.
- The known iteratee implementation traps are pinned by tests before the
  combinators grow.

## Non-Goals

- No keep-alive or pipelining; ADR-011 stands. The model is chosen to make
  that revisit cheap, but this RFC does not perform it.
- No chunked transfer encoding in either direction.
- No compression middleware; the taxonomy shows where it goes, nothing is
  built.
- No generalised element types or monad parameters: the stream element is
  `ByteString` and the effect monad is `IO`, concretely.
- No external streaming dependency (ADR-010).

## Proposal

### Iteratee Core

```haskell
data Stream
    = Chunk BS.ByteString
    | EndOfStream (Maybe SocketError)    -- orderly end, or transport failure

data Iter a
    = Done a Stream                      -- result plus residual input
    | NeedInput (Stream -> IO (Iter a))  -- consumer continuation
    | IterFailed FrameError Stream       -- terminal failure, residue kept

type Enumerator a = Iter a -> IO (Iter a)

run :: Iter a -> IO (Either FrameError a)  -- feeds EndOfStream, extracts
```

Decisions embodied here:

- Failure is a constructor, not an `Either` inside the result, so binds
  stay single-layered; `run` converts to `Either` at the public boundary,
  preserving ADR-009's style.
- `IterFailed` carries residue so a failure handler or a future keep-alive
  loop can resynchronise or respond before closing.
- Enumerators return the iteratee state rather than unit, per the
  composition argument in the references.
- The `Monad` instance for `Iter` owns residue threading. This is the
  classic defect site in iteratee implementations and gets the first tests.

Stream contract rules:

- A consumer given `EndOfStream` must resolve to `Done` or `IterFailed`;
  `NeedInput` after end of stream is divergence.
- End of stream may be delivered more than once (an enumerator and `run`
  may both deliver it); consumers must treat repeats as stable.
- An enumerator stops feeding as soon as the iteratee is `Done` or
  `IterFailed` and returns it unchanged.

### Producers and Sinks

```haskell
socketEnumerator :: ClientSocket -> Int -> Enumerator a
-- feeds recv chunks; maps Right "" to EndOfStream Nothing and
-- Left err to EndOfStream (Just err)

socketSinkI :: ClientSocket -> Iter ()
-- consumes chunks with sendAll until end of stream

strictEnumerator :: BS.ByteString -> Enumerator a
fileEnumerator   :: FilePath -> Enumerator a
-- fileEnumerator opens, feeds in chunks, and closes the handle itself;
-- producer-owned resource bracketing is the model's cleanup guarantee
```

### Consumers and Enumeratees

```haskell
frameHeadersI :: ParseLimits -> Iter HeaderBytes
-- scans to the CRLFCRLF terminator within maxHeaderBytes;
-- Done's residue is the body prefix, threaded onward by bind

takeN :: Int -> Iter a -> Iter a
-- the Content-Length bound: the inner iteratee sees exactly n bytes then
-- end of stream; outer residue beyond n is preserved

readBodyStrict :: Int -> Iter BS.ByteString
-- bounded take-all convenience for handlers that want a strict body
```

`takeN` is the only enumeratee this RFC builds. Because every stage is
`ByteString` to `ByteString`, the general two-state enumeratee shape from
the references is avoided; future stages (dechunking, decompression) take
the same simplified form.

### Application Contract

```haskell
data RequestHead = RequestHead
    { headMethod  :: Method
    , headPath    :: [String]
    , headQuery   :: [(String, String)]
    , headHeaders :: Headers
    , headRawPath :: BS.ByteString
    }

type Application = RequestHead -> Iter Response

data ResponseBody
    = StrictBody BS.ByteString
    | StreamBody (Enumerator ())
```

- The head is parsed strictly (it is bounded by `maxHeaderBytes`); the
  pure parser shrinks to header-bytes-only and no longer sees bodies.
- The router dispatches on the head and is unchanged.
- The server pipeline per connection is
  `socketEnumerator -> (frameHeadersI >>= application)`, then the response
  head is written strictly and the body enumerator runs into
  `socketSinkI`. `FileBody` is re-expressed as
  `StreamBody (fileEnumerator path)`.
- A `StreamBody` has no known length and is close-delimited, which
  `Connection: close` (ADR-011) already makes legal. File sizes for
  `Content-Length` remain blocked on the ADR-018 `getFileSize` note.

Two contract relocations, decided here:

- The body limit moves from central parsing to the consumer side. The
  server's standard pipeline installs a default size-cap stage (a `takeN`
  variant that fails) so the old guarantee survives; handlers using
  `readBodyStrict` state their own bound explicitly.
- Unconsumed body bytes are the server's to dispose of: when a handler
  responds without draining, the server closes the connection (free under
  ADR-011). A future keep-alive loop must drain to the request boundary
  instead; the enumerator-returns-state property makes that possible.

### Middleware Taxonomy

`type Middleware = Application -> Application` is unchanged (ADR-015).
The kinds:

- Head-level middleware (auth, headers, logging, timing): plain function
  composition; no streams.
- Ingress middleware (size caps, request decompression): an enumeratee
  lifted around the application's iteratee:
  `ingress stage app = \hd -> stage (app hd)`.
- Egress middleware (response compression, future chunking): an enumeratee
  fused onto the response body enumerator before the socket sink.
- Failure-handling middleware (error pages): an `Iter` transformer that
  intercepts `IterFailed` and yields a replacement `Response`; `catchIter`
  is an ordinary function over the concrete type.

## Alternatives Considered

- WAI-style pull reader with producer pushback: rejected in design
  discussion; residual input belongs in the consumer's result, data flows
  only down the stack, and the enumerator's resource bracketing is lost in
  the reader shape.
- External streaming library (conduit/pipes/streaming): excluded by
  ADR-010 and MicroHs compatibility risk.
- Keeping the strict `Request` with a separate streaming seam: rejected;
  two application contracts drift, and the strict path is expressible as
  `readBodyStrict` in one line.

## Security Impact

- The default body size cap must be installed in the server pipeline, not
  left to handler discipline; its absence would be an unbounded-memory
  regression relative to RFC-0003.
- Header bounding is unchanged (`frameHeadersI` enforces
  `maxHeaderBytes` incrementally).
- Failure residue must never be echoed into responses.

## Reliability Impact

- Constant-memory operation removes the large-body failure mode.
- Producer-owned bracketing closes file handles on failure paths without
  try-finally at call sites.
- A handler that never consumes its body cannot wedge the connection: the
  server's close-after-response policy disposes of the stream.
- The MicroHs concurrent-transfer hang recorded in RFC-0003 is orthogonal
  (per-connection design) but constrains integration tests to the same
  single-threaded transfer patterns.

## Compatibility Impact

- `Application` changes shape: this is the breaking change of the RFC and
  carries ADR-024. `Request` with a strict body disappears in favour of
  `RequestHead` plus body iteratee; existing TestApp handlers migrate to
  `readBodyStrict` with an explicit bound.
- `MicroHttp.Http.Framing` from RFC-0003 is re-expressed on the iteratee
  core (`frameHeadersI` plus draining); its unit tests migrate to scripted
  enumerators with behaviour unchanged.
- The router's matching API is untouched; its handler payload type changes
  with `Application`.
- Both compilers must build the core; it uses plain data types and
  instances only.

## Testing and Quality Gates

- `make check` after every slice; `make test-editor-browser` after the
  TestApp migration.
- Unit tests drive iteratees with scripted in-memory enumerators (no
  sockets); loopback integration tests reuse the RFC-0003 `connectTcp`
  seam.

Test cases, simplest to most complex; the first four pin the documented
trap sites before any HTTP behaviour:

1. Given a bind across a chunk boundary, when the first iteratee finishes
   mid-chunk, then the second iteratee receives the residue. (unit)
2. Given end of stream delivered twice, when an iteratee has resolved,
   then the result is stable and no continuation is re-entered. (unit)
3. Given end of stream, when a consumer needs more input, then it resolves
   to a failure rather than `NeedInput`. (unit)
4. Given a failing iteratee, when it fails mid-chunk, then `IterFailed`
   carries the unconsumed residue. (unit)
5. Given headers split across chunks, when framing with `frameHeadersI`,
   then the head is assembled and the residue is the body prefix. (unit)
6. Given a `takeN` bound, when the inner iteratee consumes, then it sees
   exactly n bytes and outer residue is preserved. (unit)
7. Given `readBodyStrict` with a bound below the body size, when
   consuming, then the iteratee fails as body-too-large. (unit)
8. Given a strict and a file enumerator, when run into a collecting
   iteratee, then bytes round-trip and the file handle is closed on both
   success and failure. (integration)
9. Given a socket enumerator and sink over a loopback pair, when a body is
   streamed through `takeN` to a collecting sink, then bytes round-trip in
   single-threaded rounds. (integration)
10. Given the migrated TestApp save handler, when posting a body larger
    than one read buffer, then the document store holds the full body.
    (integration, replaces the RFC-0003 test case 15 shape)
11. Given a handler that responds without consuming its body, when the
    response completes, then the connection closes cleanly. (integration)

## Rollout Plan

1. Phase one: iteratee core and combinators (test cases 1 to 7).
   - [ ] `Stream`, `Iter`, `Enumerator`, `run`, and the `Monad` instance
         with residue threading.
   - [ ] `frameHeadersI`, `takeN`, `readBodyStrict`.
   - [ ] Scripted-enumerator unit suite pinning the trap sites.
2. Phase two: producers and sinks (test cases 8 and 9).
   - [ ] `strictEnumerator`, `fileEnumerator` with bracketing,
         `socketEnumerator`, `socketSinkI`.
   - [ ] Loopback integration tests in single-threaded transfer rounds.
3. Phase three: application contract and server pipeline (test cases 10
   and 11).
   - [ ] `RequestHead`, new `Application`, `ResponseBody` with
         `StreamBody`; default body-cap stage in the server pipeline.
   - [ ] Rewire `handleClient`; re-express `FileBody` and RFC-0003 framing
         on the core; migrate TestApp handlers and the router payload.
   - [ ] Middleware lifts (`ingress`, `egress`, `catchIter`) with one
         example each.
   - [ ] Flip ADR-024 to accepted; update the network design document and
         module index.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design
  contracts do not cover, stop changing the affected scope before
  inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the
  owning RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or
  user approval.

## Open Questions

- What is the default body-cap size for the standard pipeline: the current
  `maxBodyBytes` (1 MB), or larger now that memory no longer scales with
  body size?
- Should `socketEnumerator` surface an idle-read timeout, or does that
  wait for the readiness-manager work (carried over from RFC-0003)?
- Does `RequestHead` keep `requestRawPath` and the existing percent
  decoding semantics unchanged, or is this the moment to revisit them?
- Sequencing: this RFC follows RFC-0003 phase three. Does the editor
  progressive-enhancement work (RFC-0001) jump the queue, since the
  `Application` change will touch the same TestApp handlers?
