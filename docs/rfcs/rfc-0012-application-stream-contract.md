---
id: RFC-0012
name: Application As A Stream Consumer, Logging As Middleware
status: Implemented
owners:
    - alistair
created: 2026-06-13
updated: 2026-06-13
supersedes: []
superseded_by: null
---

# Application As A Stream Consumer, Logging As Middleware

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-13       |
| Started   | 2026-06-14 17:00 |
| Completed | 2026-06-14 18:05 |

## Summary

Change the `Application` contract so it consumes the raw request stream and
yields a response, rather than receiving an already-parsed `RequestHead`.
Framing and parsing stop being a fixed server-owned pipeline and become the
innermost layer of the application stack (the router); middleware wraps that
stack, with routing at the bottom. Because an `Application` now sits in the
byte stream, request logging becomes an ordinary middleware -- the outermost
one -- that taps the request stream for the first line, observes the response
flowing back up, and keeps its own per-request state for timing and sizes. The
connection layer (`handleClient`) collapses to: drive the stack, write the
response, close. The connection's own metadata that is not in the payload --
the peer address -- is captured at accept and passed to the application as a
`ConnectionInfo`, so logging (and, later, handlers) can use it. This supersedes
the connection-layer logging of ADR-029.

## Context

The walkthrough of the request lifecycle made two awkward seams obvious.
First, header framing runs in a server-owned "request pipeline"
(`frameHeadersI >>= dispatch`) that sits above the application and outside the
middleware stack -- a layer that is neither socket, app, nor middleware.
Second, request logging (RFC-0009) had to be special-cased inside
`handleClient` because the old `Application = RequestHead -> Iter StreamError
Response` only runs after a head is parsed, so a middleware at that layer
could not see a connection that fails before parsing, nor the request bytes.

Both seams share one root: the `Application` is defined over a parsed head, so
everything upstream of parsing has to live in the server. If instead the
`Application` consumes the raw request stream, parsing moves down into the
application (the router frames and parses, then hands handlers a `RequestHead`
as before), and middleware -- now a stream-level transformer -- can sit
outside framing. Logging then needs nothing special: it reads the first line
off the stream (verb and target, all an access log needs to be meaningful),
forwards every byte to the inner stack, and watches the response come back.

A logging middleware can hold per-request state for round-trip time and sizes.
The request size is not known up front -- at the first chunk only that chunk
is in hand; the declared `Content-Length` is known once the head parses, and
the bytes actually read are tallied as they are forwarded. The response size
is available because the response passes back through the layer: a strict
body's size is its serialised length, and a streaming body's bytes are counted
as they are fused through the middleware on the way to the socket (the existing
`egress` mechanism).

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- `Application` consumes the raw request stream and receives the connection's
  non-payload metadata: `type Application = ConnectionInfo -> Iter StreamError
  Response`.
- Capture the peer address at accept and carry it in `ConnectionInfo`, so the
  access log can record the client, decoded from the `sockaddr` that `accept`
  already fills (no new syscall).
- Framing, parsing, and the body bound move into the application stack as
  library combinators (the router), not the server. Handlers keep their
  `RequestHead`-based ergonomics.
- `Middleware` is a stream-level transformer (`Application -> Application`)
  that can tap the request stream and observe the response. Routing is the
  innermost (bottom) layer; middleware wraps it, outermost-first.
- Request logging is an ordinary middleware (the outermost one), holding its
  own per-request state for the first line, round-trip time, and request and
  response sizes. It is removed from `handleClient` and from `Settings`.
- The default body-size bound and the `400`/`408` error responses remain
  available as library-provided, app-composed pieces, so the safety defaults
  are not lost when framing leaves the server.
- `handleClient` collapses to driving the stack, writing the response, and
  closing.

## Non-Goals

- The HTML response builder is out of scope; RFC-0013 covers it. HTML
  responses continue to render to a `String` and pack to a `StrictBody` --
  less efficient, but it adheres to the new contracts and can be optimised
  later.
- No change to `Content-Length` behaviour or the close-delimited streaming of
  response bodies.
- Keep-alive (persistent connections) stays out, and not merely as "deferred".
  Client keep-alive is the reverse proxy's job, and nginx's default upstream
  mode is a new connection per request -- exactly our `Connection: close` per
  response -- so the proxied production path needs no keep-alive from us. Our
  own keep-alive would matter only for proxy-less deployments (local dev, the
  desktop packaging) or to pool proxy-to-upstream connections under high load.
  It is a separate RFC, and this design does not preclude it: the per-request
  `Application` composes under a future connection loop in `handleClient` that
  carries the inter-request residue forward.
- No change to the idle read/write timeouts (RFC-0006, RFC-0008) or the
  readiness manager (RFC-0005); they keep working through `recvWithin` /
  `sendAllWithin` at the socket edge.
- Handlers keep receiving a parsed `RequestHead`; this RFC does not push raw
  bytes down to handler code.

## Proposal

### The contracts

```haskell
type Application = ConnectionInfo -> Iter StreamError Response  -- conn + stream
type Middleware  = Application -> Application  -- a stream-level transformer
-- Handler signature unchanged: Captures -> RequestHead -> Iter StreamError ...
-- (RequestHead gains a requestPeer field the router fills)

-- non-payload connection metadata, captured at accept
data ConnectionInfo = ConnectionInfo
    { connPeerHost :: Host
    , connPeerPort :: Port
    }
```

`Application` loses its `RequestHead` argument and gains a `ConnectionInfo`
one. `Middleware` is then a transformer over `ConnectionInfo -> Iter
StreamError Response`: it can interpose on the input stream (tap or rewrite
request bytes), read the connection metadata, observe or replace the response
value, and decorate a streaming response body. The existing combinators are
re-expressed on the new type: `mapResponse = fmap` (per connection),
`catchIter` recovers an `IterFailed` to a `Done` response, `ingress`/`egress`
transform the request and response streams. The new capability the type
unlocks is input tapping, which is what logging needs.

### Connection metadata

The peer address is not in the request payload; it is known at accept. `accept`
already fills a peer `sockaddr_in` that the current code discards -- the same
sixteen-byte layout `boundPort` decodes for the local address -- so the peer
host and port can be read there with no `getpeername` call. (This supersedes
the RFC-0009 open question that deferred the peer address behind a new FFI.)
`MicroHttp.Network.Socket.accept` is extended to return the decoded
`ConnectionInfo` alongside the `ClientSocket`, and `handleClient` passes it to
the application. The logging middleware reads the peer from the
`ConnectionInfo` it is handed, before any parse -- it must, since it logs on
the first chunk, before a `RequestHead` exists. For handlers, the router copies
the peer into a new `requestPeer :: ConnectionInfo` field on `RequestHead`
after parsing, so a handler reads `requestPeer head`. The peer thus lives in
two places by design: `ConnectionInfo` for the pre-parse layers (logging), and
`requestPeer` for handlers. It is a small non-parsed addition to `RequestHead`
that the router fills; `parseRequestHead` itself stays payload-only.

### Framing moves into the application stack

The server no longer frames. Library combinators assemble an application:

```haskell
-- frame to CRLFCRLF, then parse
frameAndParse :: ParseLimits -> Iter StreamError RequestHead
-- frame, bound the body, route
serveRoutes :: ParseLimits -> [Route] -> Application

serveRoutes limits routes _conn =
    frameAndParse limits >>= \head ->
        takeN (declaredBodyLength head) (route routes head)
```

`route :: [Route] -> RequestHead -> Iter StreamError Response` is unchanged and
still hands handlers a parsed head, so routing is the innermost layer and
handler code is unaffected. `frameAndParse` is the bottom of the stack -- which
answers "why is framing so far up": it no longer is; it is the innermost
application step, not a server pipeline.

### Error responses and the body bound stay as defaults

The body-size bound stays inside `serveRoutes` (the `takeN` plus the
`maxBodyBytes` rejection), so an application using the router cannot
accidentally drop it. The `400`/`408` responses become a middleware:

```haskell
-- StreamParseError -> 400, StreamTimeout -> 408
withErrorResponses :: Middleware
```

It recovers a parse failure or an idle-read timeout to a written response; a
transport read failure (`StreamReadError`) stays an `IterFailed`, so the
connection simply closes with nothing to write. These are library-provided so
applications keep the defaults without the server owning a pipeline.

### Logging as the outermost middleware

```haskell
logRequests :: Logger -> Middleware
```

Because the produced `Application` takes a `ConnectionInfo` and returns an
`Iter`, the middleware has the peer address in hand from the start and begins
with an `IterM` that allocates fresh per-request state (start time, byte
counters) on each drive. It then:

- interposes on the input stream: each chunk forwarded to the inner stack is
  tallied (request bytes) and scanned until the first CRLF to log the
  `RQST` line (peer, verb, and target); the bytes are passed through unchanged
  so the router re-frames from the start;
- observes the inner's resolution: a `Done response` gives the status (and, for
  a strict body, the exact serialised size); a streaming body is decorated via
  `egress` so its bytes are counted and the last-byte time stamped as the
  response is written; an `IterFailed` is logged as `ABRT`;
- emits the terminal `RESP`/`ABRT` line with status, sizes, and duration.

`settingsLogger` is removed. The application composes logging explicitly as the
outermost middleware, for example:

```haskell
app =
    logRequests logger
        (withErrorResponses (serveRoutes (parseLimits settings) routes))
```

### Reads, chunk sizes, and slow clients

`socketEnumerator` does one `recv` per chunk, and `recv` returns whatever bytes
are in the kernel buffer at the moment of the call -- one byte up to the read
buffer size -- blocking only when the buffer is empty. It never waits to fill
the buffer, so the first chunk is the earliest available bytes, delivered
immediately; the logging and slow-client middleware act on the first packet's
worth of data with no added latency. TCP exposes no packet boundaries, so "one
packet per chunk" is neither guaranteed nor needed -- "the earliest available
bytes" is.

The socket read buffer is `settingsReadBufferBytes` (8 KiB); the unrelated
file-read chunk for streamed response bodies is `fileChunkBytes` (4 KiB). These
are independent constants with no principled difference; `fileChunkBytes`
should become a setting, and the values may be unified. This is a tidy-up note,
not a behaviour change in this RFC.

The slow-client guard splits across two layers. The hard deadline for a
*silent* socket must stay at the read (`recvWithin`, RFC-0006): during a stall
no middleware is running -- the thread is parked in `recv` below the stack --
so only the producer can bound that wait. Above it, a slow-client middleware
(the layer beneath logging) can enforce rate or deadline policy when chunks do
arrive (for example, the head must complete within a total budget) and observe
the timeout, which surfaces up the stack as `StreamTimeout`. Logging stays
outermost, so every connection is logged whichever layer ends it.

### The connection layer collapses

`handleClient` no longer frames, parses, maps errors, times, or logs. It drives
the composed stack and writes:

```haskell
-- accept now yields the peer metadata too: (ClientSocket, ConnectionInfo)
handleClient settings app client conn = do
    final <- socketEnumerator client
                (readBuffer settings) (idleRead settings) (app conn)
    outcome <- run final
    _ <- case outcome of
        -- the sink carries the write timeout; logging counts bytes
        Right response -> writeResponse (socketSink settings client) response
        Left _ -> pure (Right ())  -- aborted: nothing to write
    closeClientSocket client
```

The byte counting and the write timeout live in the sink and the logging
middleware, not here. `respondToRequestBytes` (the in-memory test seam) becomes
`strictEnumerator bytes app >>= run`, since the application now frames itself.

## Alternatives Considered

- Keep connection-layer logging (ADR-029 status quo): works, but logging stays
  a special case in `handleClient` rather than composing with everything else,
  and framing stays in a server-owned pipeline. The whole point here is to make
  logging a middleware, which the directive requires.
- Fold response writing into the iteratee so the whole serve is one
  `Iter StreamError ()` ("full onion"): considered and rejected, because then
  the application yields `()` and a logging middleware has no `Response` value
  to read the status from. Keeping `Application = Iter StreamError Response`
  gives logging the status as a value and the body bytes via `egress` -- both,
  without the fold.
- Push raw bytes all the way to handlers (drop `RequestHead` from `Handler`
  too): needless churn and worse ergonomics; routing still needs a parsed head.
  The router stays the adapter.

## Security Impact

- The body-size bound moves from the server to `serveRoutes`. It remains a
  library default applied by the router, so an application built on the router
  keeps it; an application that hand-assembles its stack must apply the bound
  itself. This is called out as a deliberate contract shift.
- The `400`/`408` responses become `withErrorResponses`; an application that
  omits it would leak `IterFailed` aborts instead of clean status responses.
  The default app assembly includes it.
- The access log still records only method and target (the first line), not
  header values or bodies, so credentials do not reach the log by default.
- `ConnectionInfo` carries the peer address, which the access log records. That
  is client metadata an operator should treat as such. It is the immediate TCP
  peer: behind a reverse proxy it is the proxy's address, not the real client's
  -- recovering the real client from `X-Forwarded-For` is a header concern and
  out of scope here (an open question below).

## Reliability Impact

- A logging middleware runs inside the request `Iter`; a throwing logger sink
  would surface as a handler failure, as today. `nullLogger` (now just an
  unused/identity logger or the absence of the middleware) cannot fail.
- The middleware allocates a small amount of per-request state via `IterM`;
  with no logging middleware composed, there is no added work, so the egress
  benches are unaffected unless logging is enabled.

## Compatibility Impact

- Breaking, internal: `Application` (now `ConnectionInfo -> ...`), `Middleware`
  (and its combinators), `Router.route` usage in the app assembly,
  `respondToRequestBytes`, and `TestApp` all change shape. `settingsLogger` is
  removed from `Settings`. `Network.Socket.accept` returns
  `(ClientSocket, ConnectionInfo)` instead of just the socket.
- `RequestHead` gains a `requestPeer :: ConnectionInfo` field (filled by the
  router from the connection). The `Handler` signature (`Captures ->
  RequestHead -> ...`) is unchanged, so handler code and the route-definition
  surface stay stable; existing handlers simply ignore the new field.
- Supersedes ADR-029 (connection-layer logging); amends ADR-015 (middleware)
  and the `Application` contract from RFC-0004. A new ADR (numbered when this
  RFC is implemented) records the stream-consumer `Application` and
  middleware-hosted logging.

## Testing and Quality Gates

- `make check` stays green.
- Unit: `serveRoutes` over in-memory bytes parses, bounds the body, and routes
  (the old `respondToRequestBytes` tests, retargeted); `withErrorResponses`
  maps a malformed request to 400 and an over-limit body to 400; the middleware
  combinators (`mapResponse`, `catchIter`, input tap) behave on the new type.
- Unit: a logging middleware over a capturing logger and an in-memory request
  records `RQST` (peer, verb, target) and a terminal `RESP` with status and
  request/response sizes, with no real socket or clock (inject both).
- Unit: `accept` decodes the expected peer host and port from a known
  `sockaddr_in` buffer (mirrors the `boundPort` decode test).
- Integration: a full request over a loopback socket through the composed stack
  logs `RQST` (with the loopback peer) then `RESP`; a peer that stalls
  mid-headers still yields a terminal `ABRT`; a large streamed response is
  counted via `egress`.

## Rollout Plan

1. Phase one: contracts and combinators.
   - [x] `ConnectionInfo`; `accept` decodes the peer from its `sockaddr` and
         returns `(ClientSocket, ConnectionInfo)`.
   - [x] New `Application`/`Middleware` types; re-express the existing
         combinators; add `frameAndParse` and `serveRoutes`.
   - [x] `withErrorResponses` middleware carrying the `400`/`408` defaults.
2. Phase two: logging as middleware.
   - [x] `logRequests` middleware (input tap, response observation, per-request
         state); remove `settingsLogger`.
3. Phase three: thin the server and migrate.
   - [x] `handleClient` drives the stack and writes; `respondToRequestBytes`
         simplified; `TestApp` composes its stack with logging outermost.
   - [x] Unit and integration tests above; `make check` green.
   - [x] ADR-032 accepted (supersedes ADR-029); update the network design
         and the request-lifecycle walkthrough.

Notes from implementation (recorded in ADR-032): `AccessEvent` carries the peer
and a `RequestLine` (method and target strings tapped from the first line)
rather than a parsed `RequestHead`. `ServerError` gained `ServerStreamFailed`
for a stream failure that produced no response. The body bound and 400/408
responses are now application-composed (`serveRoutes`/`withErrorResponses`), so
`settingsMaxBodyBytes` is the value an application threads into its limits (via
`parseLimits`) rather than a server-enforced cap. The first landing deferred
`requestPeer` and response-byte counting; a follow-up added both -- `RequestHead`
now carries `requestPeer` (filled by the router, built via an `emptyRequestHead`
default so the field cost one line, not every construction site, the
record-update pattern from the Open Questions), the `Http` -> `Socket` import it
implies being acyclic; and `logRequests` logs response bytes exactly for strict
bodies and via an egress counter for streaming bodies.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should `ParseLimits` (`maxHeaderBytes`, `maxBodyBytes`) stay in `Settings`
  and be read by the app assembly, or move to the application/router
  composition now that framing is app-level? Leaning: keep in `Settings` for
  this RFC, read via `parseLimits settings`, and revisit.
- For a strict response body the `RESP` line is logged when the response value
  flows up (size exact, time excludes the single send); for a streaming body it
  is logged at the last byte via `egress`. Is the strict-case timing precise
  enough, or should strict responses also stream through the sink so timing is
  uniform? The HTML builder (RFC-0013) makes bodies chunk-streams anyway, which
  would make this uniform for free.
- Should the body bound and `withErrorResponses` be bundled into a single
  `defaultApp`-style assembly so applications cannot forget either, at the cost
  of less composability?
- Should `ConnectionInfo` also carry the local address, an accept timestamp, or
  (later) TLS details? Kept to peer host and port here; the record is
  extensible.
- Could a single layer frame and parse the `RequestHead` once and pass the
  complete head down, so the router does not re-parse, while the logger keeps
  its own tiny first-line scan (it must act before the full head exists)? An
  optimisation worth weighing; the reparse cost is small, so it is not required
  here. A partial/incremental shared parse is explicitly not pursued (it needs
  a partial-head type and cross-chunk parsing for little gain), and any shared
  parsed head would be its own value, never folded into `ConnectionInfo`, which
  stays transport-only metadata.
- For proxied deployments, the real client address is in `X-Forwarded-For`, not
  the TCP peer. Trusting and parsing that header is a separate concern (a
  middleware) and is out of scope for this RFC.
