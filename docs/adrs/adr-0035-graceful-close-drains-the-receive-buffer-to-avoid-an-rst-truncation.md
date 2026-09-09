---
id: ADR-0035
name: Graceful Close Drains The Receive Buffer To Avoid An RST Truncation
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0035: Graceful Close Drains The Receive Buffer To Avoid An RST Truncation

## Context

An application may answer without consuming the whole request (RFC-0012
lets the response resolve from the head alone). On macOS/BSD, `close()` on a
socket that still has unread receive data sends a `RST` instead of a `FIN`, and
that `RST` can race the peer's read and discard data the peer has buffered but
not yet read -- truncating the response. The bug is timing-dependent (it bit
under load) and was invisible until RFC-0014's end-to-end test asserted the
exact response bytes; earlier tests only checked that the status line was
present, which survives truncation.

## Decision

Before closing a client connection, `handleClient` calls
`closeClientSocketGraceful`, which drains whatever is currently in the receive
buffer with a non-blocking sweep (read until a read would block, end of stream,
or error) and then closes. With no unread receive data, the close is an orderly
`FIN` that delivers the queued response. The sweep never waits for the peer, so
it cannot stall the handler, and it is the same for every response, not just a
`FileBody`.

## Consequences

Responses are no longer truncated by an `RST` when the handler
left request bytes unread -- a latent correctness bug fixed for all bodies, and
the precondition for `sendfile` file responses (RFC-0014) to arrive intact. The
drain only clears bytes already buffered; a client still trickling a body the
application ignored could in principle leave data unread, but that is the same
best-effort lingering-close behaviour common to connection-close servers, and
the bounded sweep keeps the handler responsive.
