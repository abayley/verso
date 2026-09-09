---
id: ADR-0006
name: Start With a Small Local Test Harness
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0006: Start With a Small Local Test Harness

## Context

MicroHs documentation says common test packages can compile, but early
workspace setup had not verified installed test dependencies.

## Decision

Start with a small local Hspec-shaped test harness.

## Consequences

Pure modules can get tests immediately; moving to `HUnit` or
`hspec` remains an option after package verification.
