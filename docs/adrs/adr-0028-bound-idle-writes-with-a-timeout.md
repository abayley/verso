---
id: ADR-0028
name: Bound Idle Writes With A Timeout
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0028: Bound Idle Writes With A Timeout

## Context

ADR-0027 bounded the read path but left the symmetric hole on the
write path. After the application produces a response, the server writes it
with `sendAll`; if the client stops reading, the kernel send buffer fills,
`sendAll` parks indefinitely on `waitForWriteFD` (ADR-0026), and the handler
thread and its active-handler slot are held for as long as a slow reader
chooses, the same exhaustion vector in the other direction. The mechanism is
already proven: `waitForWriteFD` parks on the same poll queue, and the
runtime's `thread_intr` unlinks a parked thread regardless of read or write
intent, so the ADR-0027 fork-based `timeout` reaches it unchanged. Unlike the
read side, a write timeout can happen after the response head is on the wire,
so there is no status-code answer; the only correct action is to close.

## Decision

Bound the idle wait before a would-block write, mirroring ADR-0027.
`sendAllWithin` takes an idle timeout; when a send would block it waits with
`timeout n (waitForWriteFD fd)` and reports a reached deadline as a timeout
`SocketError` (`isTimeoutError`). `sendAll = sendAllWithin 0` keeps existing
callers unchanged. The server's `socketResponseWriter` is the single writer
for both strict and streaming response bodies, so threading the timeout
through it bounds every write; a timed-out write surfaces as the existing
`ServerWriteFailed` and the connection closes, with no new error case or
response. `settingsIdleWriteTimeoutMicros` defaults to 30 s; a non-positive
value disables it. The design is RFC-0008.

## Consequences

A slow or stalled reader can no longer hold a handler thread or
its QSem slot indefinitely; with ADR-0027 and ADR-0028, neither a slow sender
nor a slow reader can. A timer thread is forked only when a write would
actually block, so a draining peer keeps the egress throughput. The default
becomes a finite 30 s write wait rather than indefinite; operators can
disable it. The bound is per idle wait, not a total-response budget, and
covers the response head and body, including a streaming `StreamBody`. A
timeout variant of the non-server `socketSinkI` is deferred until a caller
needs it.
