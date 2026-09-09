---
id: ADR-0023
name: Frame Requests With an Incremental Reader
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0023: Frame Requests With an Incremental Reader

## Context

The server reads a request with a single `recv` of at most one
buffer, so requests split across TCP segments or larger than the buffer are
truncated, and the configured body limit is unreachable. The HTTP parser is
pure and should stay free of IO, so completeness must be established before
parsing.

## Decision

Frame requests with an incremental reader that consumes chunks
from an injected source until the header terminator and the declared
`Content-Length` are satisfied, enforcing header and body limits as data
arrives. `recv` returning an empty `ByteString` is the orderly end-of-stream
signal. The design and test plan are RFC-0003.

## Consequences

The reader is unit-testable with scripted chunk sources and
becomes the chunk seam for future streaming request bodies. The parser
continues to receive complete request bytes. One request per connection
(ADR-0011) and the chunked-transfer-encoding rejection are unchanged.
