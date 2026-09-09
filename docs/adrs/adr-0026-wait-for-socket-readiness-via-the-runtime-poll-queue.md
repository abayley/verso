---
id: ADR-0026
name: Wait For Socket Readiness Via The Runtime Poll Queue
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0026: Wait For Socket Readiness Via The Runtime Poll Queue

## Context

The socket adapter's would-block retry loops slept a fixed 1 ms
(`threadDelay`) before retrying, the RFC-0003 workaround for the
single-OS-thread runtime where a blocking syscall would freeze everything.
The post-RFC-0004 benches showed this caps request/response turnaround at
~50 MB/s against a ~2.3 GB/s saturated ceiling: an operation hits `EAGAIN`
once, sleeps a millisecond, then finds the data already present. The
MicroHs runtime already maintains a `poll()`-based I/O wait queue and
exposes `waitForReadFD`/`waitForWriteFD` (`IO.waitrdfd`/`IO.waitwrfd`)
under `WANT_IO_POLL`, which the unix runtime enables.

## Decision

On a would-block result, park the current green thread on the
runtime poll queue with `waitForReadFD` (`recv`, `accept`) or
`waitForWriteFD` (`sendAll`, `connectTcp`) and retry, instead of
`threadDelay`. Sockets stay non-blocking; the public
`IO (Either SocketError a)` interface is unchanged (ADR-0009). The design
is RFC-0005.

## Consequences

Request/response throughput rises about 20-30x (the
single-threaded ping-pong bench moved from ~50 MB/s to ~1-1.5 GB/s),
toward the saturated ceiling, with no busy-poll. The single-OS-thread
cooperative model is preserved: no operation blocks in a syscall; only the
scheduler blocks, in one `poll()` over every waiting descriptor. The
runtime's `MAX_POLL_FDS` (100) now bounds simultaneously-waiting
descriptors, so it and `settingsMaxActiveHandlers` (32) should be kept
consistent. The forked-thread ByteString-corruption bug recorded in
RFC-0003 is orthogonal and unaddressed.
