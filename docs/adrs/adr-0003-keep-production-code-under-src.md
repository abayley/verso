---
id: ADR-0003
name: Keep Production Code Under `src/`
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0003: Keep Production Code Under `src/`

## Context

The spike code is useful evidence, but it contains proof-oriented
shortcuts and platform assumptions.

## Decision

Keep production modules under `src/`.

## Consequences

Production modules must be copied or rewritten into `src/`; they
must not import from `spike/`.
