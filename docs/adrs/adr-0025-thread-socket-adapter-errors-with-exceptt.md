---
id: ADR-0025
name: Thread Socket Adapter Errors With ExceptT
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0025: Thread Socket Adapter Errors With ExceptT

## Context

`MicroHttp.Network.Socket` acquires resources in sequences where
every step is fallible and every failure after the file descriptor is
created must close it. Expressed as explicit `Either` case-matches this
nests five levels deep in `listenTcp`, repeating the same close-and-return
cleanup at each level, which is hard to read and easy to get wrong. The
project avoids heavy frameworks, but `mtl` and `transformers` are small,
dependency-light libraries already present and compiled in the MicroHs
package database, not frameworks in that sense.

## Decision

Thread the socket adapter's acquire sequences through
`ExceptT SocketError IO` internally, with a single `closingOnError`
combinator that closes the descriptor if any later step fails. `ErrorT`
(`Control.Monad.Error`) is not used: it is removed in `mtl` 2.3 and was
always the wrong tool. The public operations keep their
`IO (Either SocketError a)` signatures (ADR-0009 is unchanged); `runExceptT`
produces that type at the module boundary.

## Consequences

Production code gains an `mtl` dependency, used only inside
the socket adapter. The deep case-staircases in `listenTcp`, `accept`,
`connectTcp`, and `boundPort` become linear do-blocks, and the
file-descriptor cleanup on a mid-acquisition failure is expressed once
rather than at every failure site. Those cleanup paths require a forced
syscall failure to exercise and remain unit-untested; they are preserved
by construction. Other modules continue to use plain `Either`/`Iter`
results; this ADR does not adopt monad transformers project-wide.
