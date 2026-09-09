---
id: ADR-0032
name: Application As A Stream Consumer, Logging As Middleware
status: Accepted
owners:
    - Alistair Bayley
supersedes: [ADR-0029]
superseded_by: null
related_rfcs: []
---

# ADR-0032: Application As A Stream Consumer, Logging As Middleware

> Status: Accepted. Supersedes ADR-0029.

## Context

Framing ran in a server-owned pipeline above the application and
outside the middleware stack, and request logging was special-cased inside
`handleClient` because the old `Application = RequestHead -> Iter` only ran
after a head parsed -- so a middleware there could not see a connection that
failed before parsing, nor the request bytes.

## Decision

`Application` becomes `ConnectionInfo -> Iter StreamError Response` --
it consumes the raw request stream and receives the connection's non-payload
metadata (the peer). Framing, parsing, and the body bound move into the
application stack as `Router.serveRoutes`/`frameAndParse`, with routing the
innermost layer; `route` stays handler-facing (`Captures -> RequestHead ->
...`). `Middleware = Application -> Application` is a stream-level transformer;
`withErrorResponses` maps a parse failure to 400 and an idle-read timeout to
408 (a read failure stays an abort), and `logRequests` is the outermost
middleware -- it taps the first line for the peer/method/target, times the
request, counts request bytes, and emits the access-log events. `handleClient`
collapses to: drive the stack, write the response, close. `ConnectionInfo`
lives in `MicroHttp.Network.Socket` and is decoded by `accept` from the
`sockaddr` it already fills (no `getpeername`).

## Consequences

logging is an ordinary middleware that sees the request bytes
and the response, so the connection-layer special case (ADR-0029) is gone and
`settingsLogger` is removed; the application composes `logRequests`. The body
bound and the 400/408 responses are now application-composed
(`serveRoutes`/`withErrorResponses`), so `Settings.maxBodyBytes` is the value
an application threads into its limits rather than something the server
enforces directly. `ServerError` gains `ServerStreamFailed` for a stream
failure that produced no response. The initial landing deferred two pieces that
a follow-up then added: `RequestHead` now carries `requestPeer`, filled by the
router from the connection and built via an `emptyRequestHead` default so the
field addition was a one-line change rather than touching every construction
site; and `logRequests` now logs response bytes -- exact for a strict body
(from its serialised length) and counted through an egress stage for a
streaming body (the head length plus the body bytes, logged when the body
finishes). The design is RFC-0012.
