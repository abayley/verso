---
id: ADR-0001
name: Use Small Public Modules
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0001: Use Small Public Modules

## Context

MicroHs support is exploratory, so FFI, parsing, rendering, routing, and
state decisions need to remain independently replaceable.

## Decision

Keep public modules small and focused.

## Consequences

`src/` contains `MicroHttp` plus focused `MicroHttp.*` modules
rather than one large framework module.
