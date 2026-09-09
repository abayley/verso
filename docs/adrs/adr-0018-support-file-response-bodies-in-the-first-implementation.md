---
id: ADR-0018
name: Support File Response Bodies in the First Implementation
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0018: Support File Response Bodies in the First Implementation

## Context

File response support is useful for static assets and large content,
and the type-level cost is low if it is modelled as a `ResponseBody` variant.

## Decision

Support file response bodies in the first implementation.

## Consequences

`ResponseBody` includes a file case. Strict bodies can still be
serialised with `Content-Length`; file bodies are written by the server or
response writer in chunks. The first file response implementation should not
require an external streaming library. MicroHs does not currently export
`getFileSize`, so file responses may initially be close-delimited unless a small
file-size capability is added.
