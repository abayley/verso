---
id: ADR-0005
name: Start Build Automation With `Makefile`
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0005: Start Build Automation With `Makefile`

## Context

Direct `mhs` commands are the lowest-friction way to keep production
modules testable before package metadata stabilises.

## Decision

Use `Makefile` as the first build automation entrypoint.

## Consequences

`make check` is the standard quality gate. It runs documentation
linting, Haskell format checks, HLint, and production tests. Spike builds remain
available through dedicated targets, but they are historical or design checks
rather than part of the default gate. Cabal or MicroCabal can be added after
production modules settle.
