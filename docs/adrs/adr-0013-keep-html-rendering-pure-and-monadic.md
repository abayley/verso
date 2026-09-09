---
id: ADR-0013
name: Keep HTML Rendering Pure and Monadic
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0013: Keep HTML Rendering Pure and Monadic

## Context

A pure builder gives convenient composition without coupling rendering
to IO, state, sockets, or a heavyweight framework.

## Decision

Keep HTML rendering pure and monadic.

## Consequences

`MicroHttp.Html` exposes a local combinator API; handlers render
HTML values into response bodies.
