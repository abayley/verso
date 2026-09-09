---
id: ADR-0027
name: Bound Idle Reads With A Timeout
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0027: Bound Idle Reads With A Timeout

## Context

After ADR-0026 a would-block read parks indefinitely on the runtime
poll queue, so a stalled or silent peer holds a handler thread and an
active-handler slot until it acts (the slowloris exhaustion case). The wait
primitive (`waitForReadFD`) has no deadline. Two preconditions are now met:
the MicroHs `forkIO` ByteString-corruption bug no longer reproduces on the
installed toolchain (so the fork-based `System.Timeout` is sound), and
`timeout` interrupts a thread parked in `waitForReadFD` (verified by a spike
on a never-ready descriptor).

## Decision

Bound the idle wait between reads, not each read. `recvWithin`
takes an idle timeout; when a read would block it waits with
`timeout n (waitForReadFD fd)` and reports a reached deadline as a timeout
`SocketError` (`isTimeoutError`). `socketEnumerator` maps that to a
`StreamTimeout` stream error, and the server answers `408 Request Timeout`.
`recv = recvWithin 0` keeps existing callers unchanged.
`settingsIdleReadTimeoutMicros` defaults to 30 s; a non-positive value
disables it. The design is RFC-0006.

## Consequences

A slow or silent peer's read is bounded, freeing the handler
and its QSem slot. A timer thread is forked only when a read would actually
block, so steady transfers keep the ADR-0026 throughput. The default
behaviour changes from an indefinite wait to a finite 30 s one; operators
can disable it. The bound is per idle wait, not a total-request budget, and
covers both the header and body reads. A write/idle-send timeout for slow
readers on the response path is deferred.
