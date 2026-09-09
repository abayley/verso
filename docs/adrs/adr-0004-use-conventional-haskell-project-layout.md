---
id: ADR-0004
name: Use Conventional Haskell Project Layout
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0004: Use Conventional Haskell Project Layout

## Context

`src/`, `test/`, `app/`, `bench/`, and one Cabal file are familiar to
Haskell readers and leave room for `mcabal` later.

## Decision

Use a conventional Haskell project layout.

## Consequences

Tests mirror `src/` module paths under `test/`; executable entry
points live in `app/`.
