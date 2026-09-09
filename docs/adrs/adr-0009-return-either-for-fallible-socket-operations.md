---
id: ADR-0009
name: Return `Either` for Fallible Socket Operations
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0009: Return `Either` for Fallible Socket Operations

## Context

The server needs to distinguish accept, read, write, bind, listen, and
close failures without crashing the whole process or hiding recoverable
conditions behind exceptions.

## Decision

Return `Either` for fallible socket operations.

## Consequences

Public socket operations return `IO (Either SocketError a)`;
negative FFI results are converted to `Left`.
