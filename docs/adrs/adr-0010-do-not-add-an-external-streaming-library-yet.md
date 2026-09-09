---
id: ADR-0010
name: Do Not Add an External Streaming Library Yet
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0010: Do Not Add an External Streaming Library Yet

## Context

Streaming large responses is useful, but adding a streaming dependency
before the strict request/response path exists would create extra compatibility
work and design surface.

## Decision

Do not add an external streaming library yet.

## Consequences

Use a small local response-body shape for file streaming. Avoid an
external streaming package until MicroHs compatibility and actual pressure are
clear.
