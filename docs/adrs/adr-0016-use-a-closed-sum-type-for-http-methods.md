---
id: ADR-0016
name: Use a Closed Sum Type for HTTP Methods
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0016: Use a Closed Sum Type for HTTP Methods

## Context

The first server targets browser and htmx workflows. A closed method
type gives route matching and method override code simple, total pattern matches
without carrying arbitrary method text through the application.

## Decision

Use a closed sum type for HTTP methods.

## Consequences

The parser chooses the `Method` constructor at parse time. Unknown
or extension methods are rejected as unsupported input rather than preserved in
`Request`.
