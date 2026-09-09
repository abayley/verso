---
id: RFC-0005
name: Socket Readiness Waiting
status: Implemented
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Socket Readiness Waiting

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-12       |
| Started   | 2026-06-12 12:22 |
| Completed | 2026-06-12 12:30 |

## Summary

Replace the fixed 1 ms `threadDelay` busy-poll in the socket adapter's
would-block retry loops with the MicroHs runtime's own poll-queue, via the
`waitForReadFD` / `waitForWriteFD` primitives. On `EAGAIN`, a socket
operation parks the current green thread on the runtime's I/O wait queue
until the descriptor is ready, instead of sleeping a millisecond and
retrying. The scheduler already performs a single `poll()` over all waiting
descriptors and wakes the right thread, so this is cooperative and
multi-connection-friendly. The public `IO (Either SocketError a)` interface
is unchanged.

## Context

The benches added after RFC-0004 quantified the cost of the
RFC-0003 workaround. The single-threaded ping-pong bench
(`bench/SocketBench.hs`) tops out at ~50 MB/s, while the saturated
two-process bench (`bench/SocketReceiver.hs` + sender) sustains ~2.3 GB/s
for the same `recv` loop. The ~45x gap is the `threadDelay pollDelayMicros`
(1 ms) sleep: in request/response turnaround a socket operation hits
`EAGAIN` once, sleeps a millisecond, then finds the data already there, so
throughput is bounded by the poll granularity, not the socket.

RFC-0003 chose the 1 ms poll because the MicroHs runtime is effectively one
OS thread: a blocking syscall would freeze the whole runtime, preventing
other connection handlers and the accept loop from running. RFC-0003
deferred the proper fix to "the readiness-manager work where time-based
waiting gets a proper home" (its Open Questions). This RFC is that work.

The enabling finding is that MicroHs already has the mechanism, it was only
unused:

- The runtime scheduler maintains an I/O wait queue (`pollq` in
  `eval.c`). `check_pollq` builds a `struct pollfd[]` from all parked
  threads and calls `poll()` once, moving any thread whose descriptor is
  ready back onto the run queue. The main scheduler blocks in that `poll()`
  with an indefinite timeout when only I/O waiters remain, and otherwise
  with a timeout derived from pending `threadDelay`s.
- The `IO.waitrdfd` / `IO.waitwrfd` primitives park the current thread on
  `pollq` for `POLLIN` / `POLLOUT` and reschedule. They are bound in
  `Primitives` as `primWaitReadFD` / `primWaitWriteFD` and wrapped by
  `System.IO.FD` as `waitForReadFD` / `waitForWriteFD`.
- The unix runtime config defines `WANT_IO_POLL 1`, so the queue is
  compiled in. On that path the primitive returns `0` on wake and never
  returns `-1` (the `-1`/`EINVAL` result is only the compile-time
  no-poll fallback), so `waitForReadFD` does not throw and the
  `Either`-based error discipline (ADR-0009) is preserved.

This keeps the single-OS-thread cooperative model that RFC-0003 required:
no individual operation blocks in a syscall; only the scheduler blocks, in
one `poll()` that covers every waiting descriptor at once.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Remove the fixed-latency poll from request/response turnaround so
  throughput is bounded by the socket, not the 1 ms sleep.
- Keep the cooperative single-OS-thread model: no operation blocks the
  runtime; the scheduler's single `poll()` is the only blocking wait.
- Keep the public socket interface and its `Either` error contract
  unchanged.

## Non-Goals

- No change to the one-thread-per-connection model or ADR-0011.
- No idle-read timeout yet; this RFC gives time-based waiting its home but
  the timeout policy is a later slice.
- No fix for the MicroHs forked-thread ByteString-corruption bug recorded
  in RFC-0003; that is an orthogonal upstream issue.
- No portability changes (the BSD `sockaddr_in` layout stays a separate
  RFC).

## Proposal

In `MicroHttp.Network.Socket`, replace `threadDelay pollDelayMicros` in each
would-block retry loop with a readiness wait on the descriptor, then retry:

- `recv` (`recvLoop`): on `EAGAIN`/`EWOULDBLOCK`, `waitForReadFD fd` then
  retry.
- `accept` (`acceptLoop`): on would-block, `waitForReadFD fd` on the listen
  descriptor then retry.
- `sendAll` (`sendLoop`): on would-block, `waitForWriteFD fd` then retry.
- `connectTcp` (`connectLoop`): on `EINPROGRESS`/`EALREADY`/would-block,
  `waitForWriteFD fd` then retry (a connecting socket signals completion by
  becoming writable).

`pollDelayMicros` and the `Control.Concurrent (threadDelay)` import are
removed once no loop uses them. Sockets stay non-blocking; only the wait
strategy changes.

Behaviour is otherwise identical: the loops still retry on would-block, still
map other errno values to `SocketError`, still treat an empty `recv` as end
of stream. A descriptor that becomes ready with `POLLHUP` (peer closed)
wakes the thread too, and the retry then observes the close.

## Alternatives Considered

- Shorter `threadDelay`: reduces but does not remove the fixed-latency
  penalty, and a very short delay busy-spins, starving other threads.
- A blocking `recv`/`poll(fd, -1)` per operation: freezes the single-OS-thread
  runtime, the exact failure RFC-0003 avoided.
- A bespoke single-thread event loop over all descriptors: a large
  rearchitecture away from one-thread-per-connection, and redundant given
  the runtime scheduler already is that event loop.

## Security Impact

- No change to parsing, limits, or the body cap.
- Removing the busy-poll slightly reduces a slow-peer's ability to keep a
  handler thread spinning, but a stalled peer still occupies a handler slot;
  the idle-read timeout (a non-goal here) remains the real mitigation.

## Reliability Impact

- A handler waiting on a descriptor no longer wakes every millisecond, so
  many idle connections cost scheduler `poll()` slots rather than steady
  wakeups.
- `MAX_POLL_FDS` in the runtime (100) bounds simultaneously-waiting
  descriptors; beyond it the runtime errors. The current
  `settingsMaxActiveHandlers` default (32) is well within that, but the two
  limits are now related and should be kept consistent.
- The single-OS-thread model is unchanged, so the RFC-0003
  concurrent-transfer constraints on integration tests still hold.

## Testing and Quality Gates

- `make check` stays green: the loopback integration suite
  (`SocketSpec`, `ServerSocketSpec`, `StreamSpec`, `TestAppSpec`) exercises
  `recv`/`sendAll`/`accept`/`connect` over real sockets and is the
  behaviour-preserving guard.
- The benches are the success signal, not a gate: the single-threaded
  ping-pong bench (`make bench-socket`) should rise from ~50 MB/s toward the
  saturated ceiling, and the saturated and iteratee benches should be at
  least unchanged.

This is a behaviour-preserving refactor of the wait strategy, so it follows
the green-to-green refactoring discipline rather than adding new unit tests;
the would-block readiness paths require a real socket and are covered by the
integration suite. The fixed-latency removal is observable only in the
benches.

## Rollout Plan

1. Phase one: readiness waiting in the socket adapter.
   - [x] Replace `threadDelay` with `waitForReadFD` / `waitForWriteFD` in
         `recv`, `accept`, `sendAll`, and `connectTcp`; remove
         `pollDelayMicros` and the `threadDelay` import.
   - [x] `make check` green; `make bench-socket` ping-pong rose from
         ~50 MB/s to ~1.0-1.5 GB/s (median per recv buffer size), toward
         the ~2.3 GB/s saturated ceiling. Integration suite unchanged at
         17 examples.
   - [x] ADR-0026 accepted; result recorded here and in the network design
         document.

### Rollout Plan Escape Hatch

- If readiness waiting reaches behaviour this RFC does not cover, stop
  changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should `settingsMaxActiveHandlers` be capped to the runtime's
  `MAX_POLL_FDS` (100), or the runtime limit raised, before keep-alive
  multiplies concurrent waiters?
- Does the idle-read timeout now belong here as a `waitForReadFD` with a
  bounded wait, or does it wait for a settings-driven slice?
