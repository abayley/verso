---
id: ADR-0015
name: Model Middleware as Application Transformations
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0015: Model Middleware as Application Transformations

## Context

Middleware should stay optional and composable rather than becoming a
framework feature.

## Decision

Model middleware as `Application -> Application` transformations.

## Consequences

`MicroHttp.Middleware` wraps behaviours such as request logging or
error responses.
