---
id: ADR-0002
name: Name the Socket Adapter `MicroHttp.Network.Socket`
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0002: Name the Socket Adapter `MicroHttp.Network.Socket`

## Context

The project needs a socket module because MicroHs does not provide the
expected `Network.Socket` API. Using `Network.Socket` would imply compatibility
with the Hackage package and create future import ambiguity.

## Decision

Name the MicroHs socket adapter `MicroHttp.Network.Socket`.

## Consequences

The server imports `MicroHttp.Network.Socket`; no production
module should expose raw socket FFI details.
