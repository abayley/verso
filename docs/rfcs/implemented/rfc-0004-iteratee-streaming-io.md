---
id: RFC-0004
name: Iteratee Streaming IO
status: Implemented
owners:
    - alistair
created: 2026-06-10
updated: 2026-06-11
supersedes: []
superseded_by: null
---

# Iteratee Streaming IO

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-10       |
| Started   | 2026-06-11 21:02 |
| Completed | 2026-06-12 09:35 |

## Summary

Adopt the iteratee and enumerator model as the streaming foundation for
request and response bodies, so the server handles bodies of any size in
constant memory. Producers (the socket, files, strict values) are
enumerators; consumers (request framing, handlers, the socket writer) are
iteratees; stream transformations (length bounding, future decompression or
chunking) are enumeratees. The `Application` contract changes: handlers
receive a strict request head and consume the body as a stream, and
responses may carry a streaming body. Middleware keeps its
`Application -> Application` shape (ADR-0015), with stream-touching
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
release, so cleanup on signalled-failure paths is owned by the producer
rather than by try-finally at call sites; and enumerators
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

This remains within ADR-0010: no external streaming library. The model is
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
- Middleware keeps the ADR-0015 `Application -> Application` type, with a
  documented taxonomy for head-level, ingress, egress, and failure-handling
  middleware.
- The known iteratee implementation traps are pinned by tests before the
  combinators grow.

## Non-Goals

- No keep-alive or pipelining; ADR-0011 stands. The model is chosen to make
  that revisit cheap, but this RFC does not perform it.
- No chunked transfer encoding in either direction.
- No compression middleware; the taxonomy shows where it goes, nothing is
  built.
- No generalised element types or monad parameters: the stream element is
  `ByteString` and the effect monad is `IO`, concretely.
- No external streaming dependency (ADR-0010).

## Proposal

### Iteratee Core

The core is a standalone, domain-free module (`MicroHttp.Iteratee`) with no
HTTP or socket vocabulary. The failure type is a parameter `e`, decided in
the 2026-06-12 design review (see below); the element stays `ByteString`
and the monad stays `IO`, per the non-goals.

```haskell
data Stream e
    = Chunk BS.ByteString
    | EndOfStream (Maybe e)              -- orderly end, or failure

data Iter e a
    = Done a (Stream e)                  -- result plus residual input
    | NeedInput (Stream e -> Iter e a)   -- pure consumer continuation
    | IterM (IO (Iter e a))              -- effect step, resolved by drivers
    | IterFailed e (Stream e)            -- terminal failure, residue kept

type Enumerator e a = Iter e a -> IO (Iter e a)

run :: Iter e a -> IO (Either e a)       -- feeds EndOfStream, extracts
```

The concrete error type lives in the domain layer (`MicroHttp.Stream`), so
the core depends on neither sockets nor the HTTP parser:

```haskell
data StreamError
    = StreamReadError SocketError        -- ingress transport failure
    | StreamWriteError SocketError       -- egress transport failure
    | StreamParseError ParseError        -- framing, parsing, or limit failure
    | StreamSourceError String           -- producer acquire failure (file open)
```

Decisions embodied here:

- The failure type is a parameter, not a fixed sum. The earlier draft baked
  `SocketError` and `ParseError` into the core (in `Stream` and a concrete
  `IterError`), coupling the "general iteratee" to TCP and HTTP. The tell:
  the core machinery (`bind`, `run`, `takeN`, `feedStream`,
  `strictEnumerator`, `resourceEnumerator`) never *constructs* a failure,
  only propagates `IterFailed`. A type the core is agnostic to, yet whose
  every value comes from a domain edge, is a parameter. This matches the
  `enumerator` package and keeps `MicroHttp.Iteratee` reusable.
- `NeedInput` holds a pure continuation; all effects live in `IterM`. With
  a continuation in `IO` (`Stream e -> IO (Iter e a)`), the `Monad` instance
  is unimplementable: `Done a residue >>= f` must feed the residue into
  `f a`, and a pure bind cannot run an `IO` continuation. Deferring the
  feed inside a new `NeedInput` deadlocks when the residue alone completes
  the next consumer: that consumer reports `NeedInput`, the socket
  enumerator blocks in `recv`, and the client is waiting for the response.
  With a pure continuation, bind feeds residue eagerly; enumerators and
  `run` resolve `IterM` steps as they drive.
- Failure is a constructor, not an `Either` inside the result, so binds
  stay single-layered; `run` converts to `Either` at the public boundary,
  preserving ADR-0009's style.
- `StreamError` is the domain instantiation, retiring RFC-0003's
  `FrameError`. Read and write transport failures are separate constructors
  so the server maps them to `ServerReadFailed` and `ServerWriteFailed`
  without guessing the direction; `StreamSourceError` covers a producer
  whose acquire fails (a file that will not open), which has no socket or
  parse meaning.
- `IterFailed` carries residue so a failure handler or a future keep-alive
  loop can resynchronise or respond before closing.
- Consumers that raise an error take it as an argument
  (`readBodyStrict :: e -> Int -> Iter e ByteString`), so even the bounded
  body reader stays in the domain-free core. HTTP-specific consumers
  (`frameHeadersI`) live in the HTTP layer and choose `StreamError`.
- Enumerators return the iteratee state rather than unit, per the
  composition argument in the references.
- The `Monad` instance for `Iter e` owns residue threading. This is the
  classic defect site in iteratee implementations and gets the first tests.

Stream contract rules:

- `Chunk ""` is legal input meaning "no data"; consumers must not treat it
  as end of stream. It is the identity residue of `pure`, so it occurs in
  normal operation.
- A consumer given `EndOfStream` must resolve to `Done` or `IterFailed`;
  `NeedInput` after end of stream is divergence.
- End of stream may be delivered more than once (an enumerator and `run`
  may both deliver it); consumers must treat repeats as stable. An
  enumerator that has reached end of stream keeps delivering `EndOfStream`
  until the iteratee resolves.
- When a `Done` or `IterFailed` residue is `EndOfStream`, bind feeds it to
  the next consumer rather than skipping it; that consumer must resolve.
- A residue is one `Stream` value, so it cannot express "buffered bytes
  followed by end of stream". A consumer holding bytes at end of stream
  keeps the bytes as `Chunk` residue; the end signal is restored by the
  next `EndOfStream` delivery, which the repeat rule makes safe.
- An enumerator stops feeding as soon as the iteratee is `Done` or
  `IterFailed` and returns it unchanged.

### Producers and Sinks

The error-agnostic producers live in the core; the socket and file ones
live in the domain layer and fix `e` to `StreamError`.

```haskell
-- core (MicroHttp.Iteratee), error-agnostic
strictEnumerator :: BS.ByteString -> Enumerator e a
resourceEnumerator
    :: IO (Maybe r)             -- acquire
    -> (r -> IO ())             -- release
    -> (r -> IO BS.ByteString)  -- read a chunk (empty = end)
    -> e                        -- error if acquire fails
    -> Enumerator e a
-- resourceEnumerator acquires, feeds chunks (empty read = end of stream),
-- and releases on every exit path -- early completion or mid-stream failure.
-- A failed acquire ends the stream with the supplied error. This is the
-- model's cleanup guarantee, expressed once and reused.

-- domain (MicroHttp.Stream), e = StreamError
socketEnumerator :: ClientSocket -> Int -> Enumerator StreamError a
-- feeds recv chunks; maps Right "" to EndOfStream Nothing and
-- Left err to EndOfStream (Just (StreamReadError err))

socketSinkI :: ClientSocket -> Iter StreamError ()
-- consumes chunks with sendAll until end of stream; a send failure is a
-- terminal StreamWriteError

fileEnumerator :: FilePath -> Enumerator StreamError a
-- a thin wrapper over resourceEnumerator (open / hGet / hClose); an open
-- failure ends the stream with StreamSourceError
```

The bracketing guarantee is tested directly: a recording fake resource
asserts release runs exactly once on completion, on a consumer that fails
mid-stream, and on a consumer that stops early, and not at all when acquire
fails. (A file-descriptor-exhaustion test was rejected: the MicroHs runtime
closes handles on garbage collection, masking a missing release.)

An idle-read timeout for `socketEnumerator` is deferred to the
readiness-manager work carried over from RFC-0003. The seam is already
named: a timeout surfaces as `EndOfStream (Just (StreamReadError err))`
with no contract change.

### Consumers and Enumeratees

```haskell
-- core (MicroHttp.Iteratee), error-agnostic
takeN :: Int -> Iter e a -> Iter e a
-- the Content-Length bound: the inner iteratee sees exactly n bytes then
-- end of stream; outer residue beyond n is preserved

readBodyStrict :: e -> Int -> Iter e BS.ByteString
-- bounded take-all for handlers that want a strict body; the over-limit
-- error is an argument, keeping the core free of HTTP vocabulary

-- HTTP layer (MicroHttp.Http.Framing), e = StreamError
frameHeadersI :: ParseLimits -> Iter StreamError BS.ByteString
-- scans to the CRLFCRLF terminator within maxHeaderBytes;
-- Done's residue is the body prefix, threaded onward by bind
```

`takeN` is the only enumeratee this RFC builds. Because every stage is
`ByteString` to `ByteString`, the general two-state enumeratee shape from
the references is avoided; future stages (dechunking, decompression) take
the same simplified form.

When the inner iteratee completes before consuming all n bytes, `takeN`
does not drain the remainder: the unread bytes stay in the outer residue.
Draining to a message boundary is the pipeline's explicit job — today the
close-per-connection policy disposes of it, and a future keep-alive loop
drains deliberately.

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
  `Connection: close` (ADR-0011) already makes legal. File sizes for
  `Content-Length` remain blocked on the ADR-0018 `getFileSize` note.

Two contract relocations, decided here:

- The body limit moves from central parsing to the consumer side. The
  server's standard pipeline installs a default size-cap stage (a `takeN`
  variant that fails) so the old guarantee survives; handlers using
  `readBodyStrict` state their own bound explicitly. The cap stays
  settings-driven (`settingsMaxBodyBytes`, default 1 MB): constant memory
  removes the server's reason to care, but the cap bounds downstream
  costs such as document-store writes, which is application policy. The
  server also still checks the declared `Content-Length` against the cap
  before reading any body bytes, as `frameRequest` does today: the parsed
  head makes the check free, and it fails fast instead of streaming and
  discarding up to the cap. Both checks answer 400, matching current
  behaviour; a move to 413 is a separate, deliberate change.
- Unconsumed body bytes are the server's to dispose of: when a handler
  responds without draining, the server closes the connection (free under
  ADR-0011). A future keep-alive loop must drain to the request boundary
  instead; the enumerator-returns-state property makes that possible.

### Middleware Taxonomy

`type Middleware = Application -> Application` is unchanged (ADR-0015).
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
  ADR-0010 and MicroHs compatibility risk.
- Keeping the strict `Request` with a separate streaming seam: rejected;
  two application contracts drift, and the strict path is expressible as
  `readBodyStrict` in one line.

## Security Impact

- The default body size cap must be installed in the server pipeline, not
  left to handler discipline; its absence would be an unbounded-memory
  regression relative to RFC-0003.
- The declared `Content-Length` is checked against the cap before any
  body bytes are read, so an over-declared body is rejected without
  consuming the stream; the streamed cap stage remains as defence in
  depth.
- Header bounding is unchanged (`frameHeadersI` enforces
  `maxHeaderBytes` incrementally).
- Failure residue must never be echoed into responses.

## Reliability Impact

- Constant-memory operation removes the large-body failure mode.
- Producer-owned bracketing closes file handles on every signalled
  failure path without try-finally at call sites. The guarantee covers
  `Either`-signalled failures, not thrown exceptions: the project's
  no-exception discipline (ADR-0009 style) is a stated assumption, and
  handler code that throws escapes the bracketing.
- A handler that never consumes its body cannot wedge the connection: the
  server's close-after-response policy disposes of the stream.
- The MicroHs concurrent-transfer hang recorded in RFC-0003 is orthogonal
  (per-connection design) but constrains integration tests to the same
  single-threaded transfer patterns.

## Compatibility Impact

- `Application` changes shape: this is the breaking change of the RFC and
  carries ADR-0024. `Request` with a strict body disappears in favour of
  `RequestHead` plus body iteratee; existing TestApp handlers migrate to
  `readBodyStrict` with an explicit bound.
- `MicroHttp.Http.Framing` from RFC-0003 is re-expressed on the iteratee
  core (`frameHeadersI` plus draining); its unit tests migrate to scripted
  enumerators with behaviour unchanged. `FrameError` is retired in favour
  of `IterError`.
- `RequestHead` is field-for-field the current `Request` minus
  `requestBody`: `requestRawPath` and the percent-decoding semantics are
  unchanged, so the phase-three diff reviews as "body relocated" only.
  The known `+`-decoding-in-path-segments defect in the parser is a
  separate fix outside this RFC.
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

Test cases, simplest to most complex; the first six pin the documented
trap sites before any HTTP behaviour:

1. Given a bind across a chunk boundary, when the first iteratee finishes
   mid-chunk, then the second iteratee receives the residue. (unit)
2. Given a bind whose residue alone completes the second iteratee, when
   the second iteratee runs, then it completes without the enumerator
   being asked for more input. (unit; the scripted enumerator asserts the
   script is not pulled again — this pins the lazy-residue deadlock)
3. Given an empty chunk fed to a waiting consumer, when the consumer
   continues, then the empty chunk is not treated as end of stream. (unit)
4. Given end of stream delivered twice, when an iteratee has resolved,
   then the result is stable and no continuation is re-entered. (unit)
5. Given end of stream, when a consumer needs more input, then it resolves
   to a failure rather than `NeedInput`. (unit)
6. Given a failing iteratee, when it fails mid-chunk, then `IterFailed`
   carries the unconsumed residue. (unit)
7. Given headers split across chunks, when framing with `frameHeadersI`,
   then the head is assembled and the residue is the body prefix. (unit)
8. Given a `takeN` bound, when the inner iteratee consumes, then it sees
   exactly n bytes and outer residue is preserved. (unit)
9. Given a `takeN` bound, when the inner iteratee completes early, then
   the unread remainder stays in the outer residue undrained. (unit)
10. Given `readBodyStrict` with a bound below the body size, when
    consuming, then the iteratee fails as body-too-large. (unit)
11. Given a bracketed `resourceEnumerator` over a recording fake, when the
    consumer completes, fails mid-stream, or stops early, then the resource
    is released exactly once; and not at all when acquire fails. (unit) A
    strict enumerator and a real-file `fileEnumerator` round-trip into a
    collecting iteratee, with a missing file surfacing as a source error.
    (integration) The fake observes bracketing because the MicroHs runtime
    closes handles on garbage collection, masking a descriptor-leak test.
12. Given a socket enumerator and sink over a loopback pair, when a body
    is streamed through `takeN` to a collecting consumer, then bytes
    round-trip in single-threaded rounds. (integration)
13. Given the migrated TestApp save handler, when posting a body larger
    than one read buffer, then the document store holds the full body.
    (integration, replaces the RFC-0003 test case 15 shape)
14. Given a handler that responds without consuming its body, when the
    response completes, then the connection closes cleanly. (integration)

## Rollout Plan

1. Phase one: iteratee core and combinators (test cases 1 to 10).
   - [x] `Stream e`, `Iter e a` (pure `NeedInput`, effects in `IterM`),
         `Enumerator e a`, `run`, and the `Monad` instance with residue
         threading, in the domain-free `MicroHttp.Iteratee`. The concrete
         `StreamError` lives in `MicroHttp.Stream` (2026-06-12 review).
   - [x] `frameHeadersI`, `takeN`, `readBodyStrict` (error-parameterised).
   - [x] Scripted-enumerator unit suite pinning the trap sites.
         (`MicroHttp.IterateeSpec`, `MicroHttp.Http.FramingSpec`)
2. Phase two: producers and sinks (test cases 11 and 12).
   - [x] `strictEnumerator` and `resourceEnumerator` (core bracketing),
         `fileEnumerator` (wrapper), `socketEnumerator`, `socketSinkI`.
   - [x] Bracketing unit suite over a recording fake; loopback and
         real-file integration tests in single-threaded transfer rounds.
         (`MicroHttp.IterateeSpec`, `MicroHttp.StreamSpec` integration)
3. Phase three: application contract and server pipeline (test cases 13
   and 14). RFC-0001 was unstarted at the end of phase two, so on the
   2026-06-12 review the order was re-decided to proceed now; RFC-0001
   will rebuild the migrated TestApp handlers against the new contract.
   - [x] `RequestHead`, new `Application` (`RequestHead -> Iter
         StreamError Response`), `ResponseBody` with `StreamBody`. The
         body cap is the `Content-Length` frame (`takeN`) plus a pre-read
         declared-length check, not a separate fail-on-exceed stage:
         `takeN` ends the body without waiting for the peer to close, and
         an over-declared or malformed length is rejected before any body
         byte is read.
   - [x] Rewire `handleClient`; `FileBody` re-expressed as `StreamBody
         (fileEnumerator path)`; RFC-0003 framing re-expressed as
         `frameHeadersI`; TestApp handlers and the router payload
         migrated. `ParseError`/`ParseLimits` extracted to
         `MicroHttp.Http.Parse` to break the `Http`-to-`Stream` cycle.
   - [x] Middleware lifts (`mapResponse`, `ingress`, `egress`,
         `catchIter`) in `MicroHttp.Middleware`, one example test each.
   - [x] Flip ADR-0024 to accepted; update the module index. (No separate
         network design document change was needed.)

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

None currently. The four questions raised at drafting were resolved in
the 2026-06-11 design review; the decisions are recorded in the Proposal,
Compatibility Impact, and Rollout Plan sections:

- Default body-cap size: stays settings-driven at the current
  `settingsMaxBodyBytes` default (1 MB); the cap is application policy,
  not server health (see Application Contract).
- Idle-read timeout: deferred to the readiness-manager work; the seam is
  `EndOfStream (Just err)` from `socketEnumerator` (see Producers and
  Sinks).
- `RequestHead` semantics: field-for-field the current `Request` minus
  `requestBody`; raw path and percent decoding unchanged, with the
  `+`-in-path-segments defect fixed separately (see Compatibility
  Impact).
- Sequencing against RFC-0001: phases one and two touch only new modules
  and start immediately; phase three follows RFC-0001 if it is ready by
  the end of phase two (see Rollout Plan).
