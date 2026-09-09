---
id: ADR-0007
name: Keep Sockaddr Construction in Haskell First
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0007: Keep Sockaddr Construction in Haskell First

## Context

The preference is to remain in Haskell. The spikes show Haskell-side
byte layout can work on macOS, and hiding it in one module limits the blast
radius.

## Decision

Keep sockaddr construction in Haskell first.

## Consequences

`MicroHttp.Network.Socket` owns all layout constants and pointer
writes. C helper functions are a fallback only if portability or safety problems
justify them.
