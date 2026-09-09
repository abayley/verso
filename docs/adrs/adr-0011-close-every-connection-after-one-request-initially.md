---
id: ADR-0011
name: Close Every Connection After One Request Initially
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0011: Close Every Connection After One Request Initially

## Context

HTTP/1.1 keep-alive requires precise request framing and connection
reuse behaviour. The first server milestone should prove request handling before
persistence.

## Decision

Close every connection after one request initially.

## Consequences

The response layer emits `Connection: close`; persistent
connections are deferred.
