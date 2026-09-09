---
id: ADR-0024
name: Stream Bodies With Iteratees and Enumerators
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0024: Stream Bodies With Iteratees and Enumerators

## Context

Request handling after RFC-0003 is correct but strict: memory is
proportional to message size, and response bodies other than files are
strict values. The project wants constant-memory streaming on both sides
without an external streaming library (ADR-0010) and without producer
pushback: the design discussion settled on the iteratee model, where
residual input lives in the consumer's result and flows forward through
monadic bind, enumerators own resource acquisition and release, and
enumerators return the consumer's final state, which a future keep-alive
loop needs.

## Decision

Implement a local iteratee core (`Stream e`, `Iter e a`,
`Enumerator e a`, concrete `ByteString` and `IO`) in a domain-free module
`MicroHttp.Iteratee`. The failure type is a parameter: the core machinery
only propagates failures, never constructs them, so the concrete error sum
`StreamError` (read/write transport, parse/limit, and producer-acquire
failures) lives in the domain layer `MicroHttp.Stream`. Resource bracketing
is expressed once as a general `resourceEnumerator` and reused by
`fileEnumerator`. Producers are enumerators (socket, file, strict value),
consumers are iteratees (framing, handlers, the socket
sink), and stream transformations are enumeratees. The `Application`
contract becomes `RequestHead -> Iter Response`, with the body consumed as
a stream and `ResponseBody` gaining a streaming variant. Middleware keeps
its `Application -> Application` shape (ADR-0015); stream-touching
middleware lifts enumeratees onto the ingress or egress pipeline. The
design and migration plan are RFC-0004.

## Consequences

Bodies of any size are handled in constant memory. The body
limit relocates from central parsing to a default size-cap stage in the
server pipeline, and handlers wanting strict bodies state an explicit
bound; the declared `Content-Length` is still checked against the cap
before any body bytes are read. The iteratee continuation is pure, with
effects confined to an explicit effect constructor, so the `Monad`
instance can feed residue eagerly; the failure type is a parameter, with
the domain vocabulary (`StreamError`) covering read, write, parse, and
producer-acquire failures and retiring RFC-0003's `FrameError`. The pure
parser shrinks to header bytes only. The
`Application` and router payload types change, and TestApp handlers
migrate. Unconsumed body bytes are disposed of by the server's
close-per-connection policy until keep-alive is revisited.
