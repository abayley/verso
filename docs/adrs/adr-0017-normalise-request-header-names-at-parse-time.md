---
id: ADR-0017
name: Normalise Request Header Names at Parse Time
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0017: Normalise Request Header Names at Parse Time

## Context

HTTP request header lookup is case-insensitive. Normalising once in the
parser keeps handlers, middleware, and body parsing from repeating the same
case-folding work.

## Decision

Normalise request header names at parse time.

## Consequences

`Headers` keeps a lower-case header-name invariant for requests.
The original request header spelling is not preserved.
