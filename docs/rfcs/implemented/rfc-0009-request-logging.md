---
id: RFC-0009
name: Request Logging
status: Implemented
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Request Logging

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-12       |
| Started   | 2026-06-12 20:51 |
| Completed | 2026-06-12 20:51 |

## Summary

Add an opt-in access log at the server's connection layer -- the outermost
layer, which wraps every accepted connection from its first bytes through to
close. Every connection produces exactly one terminal log line: a
`RESP` line once a response (including a 400 or 408) is written,
or a `ABRT` line if the connection fails without a clean response.
A `RQST` line is also emitted the moment a request head parses,
carrying the method and path. The log sink and the line format are injected
components, so the destination (stdout, a file, a test buffer) and the format
are swappable; the default format is logfmt. Logging is off by default, so
existing behaviour and the benches are unchanged until an operator supplies a
logger.

## Context

The server emits nothing observable per request today. An operator debugging
a deployment, or watching a load test, has no record of what was requested,
what was answered, how long it took, or which connections failed.

The design question is which layer the log sits at. There are three nested
layers, outermost to innermost:

1. The connection layer -- `handleClient`, which runs the request pipeline
   (`frameHeadersI >>= dispatch`) over the socket and writes the response.
   This layer touches the first bytes of a connection, frames and parses the
   head, observes a stall or reset during framing, and observes the final
   write outcome.
2. The application-middleware layer -- `MicroHttp.Middleware`, typed
   `Application -> Application`. By construction it transforms
   `RequestHead -> Response`, so the server invokes it only after the head is
   framed and parsed.
3. The request- and response-body sub-layers (ingress and egress).

Access logging belongs at layer one. The requirement is that every accepted
connection is logged, including one that sends a partial header block and
then stalls (the slowloris case) or resets before a complete request. Such a
connection never reaches layer two: there is no `RequestHead` yet, so the
server never calls the application, and a middleware there cannot run. Layer
one, by contrast, reaches a terminal outcome for every connection it
accepts -- a written response or a transport failure -- so it can guarantee a
log line for each. The application middleware is an inner layer that runs only
once a valid request already exists; it is the wrong layer for "log every
connection from the start".

The logger is still a composable, injected component (an
`AccessEvent -> IO ()` sink plus a formatter); it is simply installed at the
connection seam rather than typed as an `Application` transformation, because
that type cannot occupy the outermost layer.

The clock is available: `System.IO.TimeMilli.getTimeMilli :: IO Int` returns
wall-clock milliseconds and is in the `mhs-0.16.0.0` package db, so it works
in `src` with no new dependency. Millisecond resolution is adequate for
request latency. It is wall-clock rather than monotonic, so a clock step
could in principle skew one measurement; this is noted and left for a later
monotonic source if it matters.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Every accepted connection is logged: a `RESP` line when a
  response is written (including the 400 and 408 paths), or a
  `ABRT` line when the connection fails without a clean response.
  No connection that the server handles goes unlogged.
- A `RQST` line is emitted the moment the head parses, carrying
  method and path -- the earliest point a meaningful request line exists.
- The completion line carries the response status, the bytes written, and the
  latency in milliseconds from the start of handling to the write.
- The log sink and the line format are injected components; the default
  format is logfmt and the default sink is none (logging off), so the prior
  behaviour and the egress benches are unchanged when no logger is set.
- The access log is testable without a real clock by unit-testing the pure
  event formatter directly, and with a capturing sink over a real socket for
  the server wiring.

## Non-Goals

- No log levels, filtering, or sampling beyond the on/off of supplying a
  logger; a richer policy can come later.
- No general application logging facility for handlers to emit their own
  messages; this RFC is the access log only.
- No request/response tracing, span propagation, or correlation IDs.
- No per-packet line on the raw first bytes: a connection has no method, path,
  or peer address until the head is framed and parsed (and `getpeername` is
  not surfaced today), so the earliest informative line is `RQST`
  at parse, and a pre-parse failure is captured by the terminal
  `ABRT` line rather than a separate "bytes arrived" event.
- No monotonic-clock guarantee; wall-clock milliseconds are used.
- No log rotation or sink buffering; those are the injected sink's concern.

## Proposal

- A new module `MicroHttp.Log` defines the access-log vocabulary:
  - `type Logger = AccessEvent -> IO ()`, the injected sink.
  - `data AccessEvent`:
    - `RequestReceived RequestHead` -- the head parsed.
    - `RequestCompleted (Maybe RequestHead) Status Int Int` -- a response was
      written; the `Int`s are bytes written and duration in milliseconds. The
      head is `Maybe` because a malformed request answered with 400, or an
      idle timeout answered with 408 during the header read, has no parsed
      head (its path logs as `-`).
    - `RequestAborted (Maybe RequestHead) String Int` -- the connection
      failed without a clean response (a read failure, or a write failure
      mid-response); the `String` is a short error label and the `Int` is the
      duration in milliseconds. The head is present if the failure came after
      the head parsed. The label is a plain `String` rather than the server's
      `ServerError` so that `MicroHttp.Log` depends only on `MicroHttp.Http`;
      the server imports `MicroHttp.Log` for the `Settings` field, so carrying
      `ServerError` here would be an import cycle. The server maps its
      `ServerError` to the label (for example `ServerWriteFailed`).
  - `nullLogger :: Logger`, the no-op default (`const (pure ())`).
  - `formatLogfmt :: AccessEvent -> String`, the default formatter, and
    `logfmtTo :: (String -> IO ()) -> Logger` building a logger from a sink
    (for example `logfmtTo putStrLn`). A different format is a different
    formatter behind the same `Logger`.
- `Settings` gains `settingsLogger :: Logger`, defaulting to `nullLogger`.
  Because a function has no `Eq` or `Show`, `Settings` drops its
  `deriving (Eq, Show)`; nothing in the codebase compares or shows a
  `Settings`, so the derivation is dead. The logger is server wiring at the
  connection layer, so it belongs with the other server configuration and
  threads through `handleClient` as the idle timeouts do.
- `handleClient` is the access-log seam:
  - It records `t0 <- getTimeMilli` at entry and owns an
    `IORef (Maybe RequestHead)`.
  - `requestPipeline` takes an `onHead :: RequestHead -> IO ()` callback; on a
    successful parse, `dispatch` runs it inside an `IterM` before continuing
    to `takeN`. `handleClient` supplies an `onHead` that stores the head in
    the ref and emits `RequestReceived`. The in-memory seam
    `respondToRequestBytes` passes a no-op `onHead`, so the unit-test
    application boundary is unaffected and stays logger-free.
  - The response writer is wrapped to count bytes: an `IORef Int` incremented
    by `BS.length` per chunk, so the count covers the strict head-plus-body
    and the streaming body alike (both go through `socketResponseWriter`).
  - After handling, `handleClient` reads `t1 <- getTimeMilli`, the head ref,
    and the byte count, and emits the terminal event: `RequestCompleted` with
    the response status on a written response (success, 400, or 408), or
    `RequestAborted` with the `ServerError` on a read or write failure.
- logfmt shape:
  - `event=RQST method=GET path=/documents/home`
  - `event=RESP method=GET path=/documents/home status=200
    bytes=1234 dur_ms=12`
  - `event=RESP method=- path=- status=400 bytes=12 dur_ms=0`
    when the head did not parse.
  - `event=ABRT method=GET path=/big error=ServerWriteFailed
    dur_ms=30000` when the connection failed without a clean response.

## Alternatives Considered

- Logging as a `MicroHttp.Middleware` (`Application -> Application`): the
  middleware layer is inner, not outer -- the server invokes it only after a
  head is parsed, so it never runs for a connection that stalls or resets
  before producing a complete request, and cannot guarantee a line per
  connection. It can log method, status, and handler time for requests that
  do parse (the response value carries the head and status, and the strict
  body's size is computable from `serialiseResponse`), but "log every
  connection from the start" is structurally a connection-layer job.
- A hybrid (middleware for the received line, server hook for completion):
  two coordinated pieces sharing timing state, with no advantage over a single
  connection-layer seam that already sees both the parsed head and the write.
- Logger as a new argument to `serve`/`serveOne`/`handleClient` rather than a
  `Settings` field: spreads the wiring across every entry point and call site
  instead of the one inert config object the timeouts already use; the
  derivation it would preserve is unused.
- A monotonic clock source: more correct for latency, but no monotonic clock
  is exposed in the `mhs` lib today, and wall-clock milliseconds are adequate
  for an access log. Deferred.

## Security Impact

- The access log records request method and path; an operator should treat
  log destinations as carrying request metadata. Header values and bodies are
  not logged, so credentials in headers or form bodies do not reach the log by
  default.
- The `ABRT` line records failed connections, which aids spotting
  a slow-loris or scanning pattern, complementing the RFC-0006 and RFC-0008
  timeouts.
- No authentication or authorization behaviour changes.

## Reliability Impact

- A logger that blocks or throws runs inside `handleClient`; a throwing sink
  would surface as a handler failure. The default `nullLogger` cannot fail,
  and the built-in logfmt sink only formats and writes a line. A custom sink
  is the operator's responsibility.
- When no logger is set the added work is one `getTimeMilli` pair and a byte
  counter per request, behind the disabled path; the egress benches should be
  unchanged. The cost is justified only when a logger is set.

## Compatibility Impact

- `Settings` loses its `Eq` and `Show` instances. No code in the project
  compares or shows a `Settings`, so this is source-compatible for current
  callers; a downstream consumer relying on those instances would need to drop
  the reliance.
- `serve`, `serveOne`, and `handleClient` keep their signatures; the logger
  arrives through `Settings`, so existing call sites compile unchanged and
  default to no logging.
- `requestPipeline` gains an `onHead` parameter; it is internal (not
  exported), so this is not an external change.

## Testing and Quality Gates

- `make check` stays green.
- Unit: `formatLogfmt` on constructed `AccessEvent` values yields the exact
  logfmt lines for `RequestReceived`, a `RequestCompleted` with a head, a
  `RequestCompleted` with no head (`method=-` `path=-`), and a
  `RequestAborted`. Pure, no clock.
- Integration: `handleClient` with a capturing `Logger` over a real socket
  records `RequestReceived` then `RequestCompleted` for a normal request, with
  the right method, path, and status, `dur_ms >= 0`, and `bytes` equal to the
  response length. A second case drives the RFC-0006 stalled-peer idle path
  and asserts a terminal line is emitted (a 408 `RequestCompleted`, or a
  `RequestAborted` if the peer reset), so a stalled connection is never
  unlogged.

## Rollout Plan

1. Phase one: access log at the connection seam.
   - [x] `MicroHttp.Log` with `Logger`, `AccessEvent`, `nullLogger`,
         `formatLogfmt`, and `logfmtTo`.
   - [x] `settingsLogger` in `Settings` (default `nullLogger`); drop the
         `Settings` `deriving (Eq, Show)`.
   - [x] `requestPipeline` `onHead` callback; `handleClient` times the
         request, captures the head, counts written bytes, and emits the
         received and terminal events; `respondToRequestBytes` passes a no-op
         `onHead`.
   - [x] Unit formatter tests and integration capturing-logger tests
         (normal request and stalled-peer terminal line); `make check` green.
   - [x] Flip ADR-0029 to accepted; note it in the relevant design document.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should the logfmt line include a timestamp key, or is that the sink's job
  (for example a syslog or journald front end that stamps its own)? This RFC
  leaves the timestamp to the sink and keeps the event fields
  transport-focused.
- Should the peer address be surfaced (via `getpeername`) and added to the
  log lines? It is the conventional first field of an access log, but it
  needs a small FFI addition to the socket layer, so it is deferred to a
  follow-up rather than bundled here.
