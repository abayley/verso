---
id: ADR-0008
name: Use Strict `ByteString` at the Socket Boundary
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0008: Use Strict `ByteString` at the Socket Boundary

## Context

HTTP wire data is bytes, and the socket layer should not force text
conversion or `String` allocation. MicroHs provides `ByteString` pointer helpers
that fit concrete `CString` FFI bindings.

## Decision

Use strict `ByteString` at the socket boundary.

## Consequences

`recv` returns `ByteString`; `sendAll` accepts `ByteString`; text
decoding belongs above the wire layer.
