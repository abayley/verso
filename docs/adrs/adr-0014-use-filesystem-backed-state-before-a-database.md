---
id: ADR-0014
name: Use Filesystem-Backed State Before a Database
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0014: Use Filesystem-Backed State Before a Database

## Context

Initial application state does not need a traditional database, and a
filesystem adapter keeps persistence explicit and inspectable.

## Decision

Use filesystem-backed state before a database.

## Consequences

`MicroHttp.Store.FileSystem` owns atomic-write and serialisation
concerns; higher layers depend on a small store API.
