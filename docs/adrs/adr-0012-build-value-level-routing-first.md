---
id: ADR-0012
name: Build Value-Level Routing First
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0012: Build Value-Level Routing First

## Context

Value routing is enough for htmx endpoints and is simpler under MicroHs
extension constraints.

## Decision

Build value-level routing first.

## Consequences

`MicroHttp.Router` is production scope; `MicroHttp.Router.Typed` is
optional and layered.
