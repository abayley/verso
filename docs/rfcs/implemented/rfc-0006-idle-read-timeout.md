---
id: RFC-0006
name: Idle Read Timeout
status: Implemented
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Idle Read Timeout

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-12       |
| Started   | 2026-06-12 14:31 |
| Completed | 2026-06-12 14:31 |

## Summary

Bound how long a request read waits for a stalled peer. When a `recv` would
block, the readiness wait (RFC-0005) is given a deadline: if no data arrives
within `settingsIdleReadTimeoutMicros`, the read fails with a timeout and the
server answers `408 Request Timeout` and closes. The bound is on the idle
wait between reads, not on each read, so a read that has data returns
immediately with no timer; a timer is armed only when the operation would
actually block. This frees a handler and its active-handler slot from a slow
or silent peer (the slowloris exhaustion case).

## Context

RFC-0003 deferred time-based waiting until the readiness manager gave it "a
proper home"; RFC-0005 provided that home by parking would-block reads on the
runtime poll queue. Two facts made the timeout safe to build now:

- The MicroHs ByteString-corruption-after-`forkIO` bug recorded in RFC-0003
  no longer reproduces on the installed toolchain (the `evalbytestring`
  slice-save workaround is present; `spike/MicroHttp/Spike11.hs` now prints
  the correct lengths). `System.Timeout.timeout` forks a timer thread, so a
  fork-based timeout would have been unsafe before.
- `timeout` interrupts a thread parked in `waitForReadFD`: a spike parking on
  a never-ready pipe descriptor under `timeout` returns `Nothing` after the
  delay. The runtime's `thread_intr` unlinks a thread from the poll queue
  when an asynchronous exception is delivered, so the forked timer's
  `throwTo` reaches the parked wait.

The wait primitive itself has no deadline (`primWaitReadFD :: Int -> IO Int`
takes only a descriptor), so the deadline is `timeout n (waitForReadFD fd)`,
which forks a timer per armed wait. Arming only on would-block keeps that off
the hot path: a 512 MB body read in 8 KB chunks would otherwise fork ~64k
timers; bounding the idle wait instead forks only when a read genuinely has
nothing to read.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- A stalled or silent peer cannot hold a handler thread (and an active
  handler slot) indefinitely during a request read.
- The bound is on the idle wait, so it adds no per-read cost when data is
  flowing and arms a timer only when a read would block.
- Disabled by a non-positive setting, preserving the previous behaviour
  exactly.
- The public socket interface keeps its `Either` error contract (ADR-0009).

## Non-Goals

- No write/idle-send timeout (a slow reader on the response path); this RFC
  is the read side only.
- No accept timeout: idling on `accept` waiting for connections is the
  intended behaviour.
- No total-request-time budget; the bound is per idle wait, not on the whole
  request.
- No keep-alive; ADR-0011 stands.

## Proposal

- `Settings` gains `settingsIdleReadTimeoutMicros :: Int`; `<= 0` disables
  the timeout. `defaultSettings` sets 30 s.
- `MicroHttp.Network.Socket` gains
  `recvWithin :: Int -> ClientSocket -> Int -> IO (Either SocketError BS.ByteString)`,
  the idle timeout as the first argument; `recv = recvWithin 0` keeps the
  existing signature and callers. When a `recv` would block, `recvWithin`
  waits for read readiness bounded by the timeout: disabled means the
  RFC-0005 indefinite `waitForReadFD`; otherwise `timeout n (waitForReadFD
  fd)`, and a `Nothing` (deadline reached) returns
  `Left (SocketError "recv" eTIMEDOUT)`. `isTimeoutError :: SocketError ->
  Bool` is exported so layers above need not know the errno.
- `MicroHttp.Stream` adds the `StreamTimeout` case to `StreamError`.
  `socketEnumerator` takes the idle timeout, uses `recvWithin`, and maps a
  timeout `recv` failure to `EndOfStream (Just StreamTimeout)` (other read
  failures stay `StreamReadError`).
- `MicroHttp.Server`: `handleClient` passes `settingsIdleReadTimeoutMicros`
  into `socketEnumerator`; a pipeline that fails with `StreamTimeout` is
  answered with `408 Request Timeout` (then the connection closes as usual),
  distinct from a transport read failure (`ServerReadFailed`, close with no
  response) and a framing/parse failure (`400`).

The timeout covers both the header read and the body read, because
`socketEnumerator` drives the whole request through `recvWithin`.

## Alternatives Considered

- Timeout around each `recv`: forks a timer per chunk, which would erase the
  RFC-0005 throughput win. Rejected for bounding the idle wait instead.
- Total-request-time budget via one `timeout` around the pipeline: simpler
  but coarser; a peer dribbling one byte per interval under the budget still
  resets nothing. The idle bound is the standard slow-peer guard.
- A new runtime primitive `waitrdfd(fd, timeout)`: avoids the per-wait fork
  but is an upstream MicroHs change, out of scope.

## Security Impact

- Directly mitigates slow-peer resource exhaustion on the read path: a
  handler slot is reclaimed after the idle bound rather than held until the
  peer acts.
- The default is now a finite wait (30 s) rather than indefinite; an
  operator can disable it with `<= 0` but the safe default is on.

## Reliability Impact

- A timer thread is forked only when a read would block, so steady transfers
  are unaffected; the post-RFC-0005 benches should be unchanged.
- The forked-timer path depends on the toolchain's `forkIO` being sound,
  which the Spike11 check confirms on the installed MicroHs.
- A timed-out read closes the connection after a 408, freeing the QSem slot.

## Testing and Quality Gates

- `make check` stays green; the existing loopback integration suite confirms
  normal reads are unaffected (they complete well within the 30 s default).
- New integration test: a peer sends a partial request then stalls; with a
  short idle timeout the server answers 408 and the call returns promptly
  rather than hanging. This also verifies that `timeout` interrupts a
  poll-queue-parked read in the server path, not just the spike.

A strict red-first test is impractical here because the pre-feature
behaviour is an indefinite hang rather than a failing assertion; the test is
added with the implementation and asserts the 408-within-timeout outcome,
which depends on the feature (it hangs with the timeout disabled).

## Rollout Plan

1. Phase one: idle read timeout.
   - [x] `recvWithin` and `isTimeoutError` in `MicroHttp.Network.Socket`;
         `recv = recvWithin 0`.
   - [x] `StreamTimeout` in `MicroHttp.Stream`; `socketEnumerator` takes the
         idle timeout and maps a timeout to it.
   - [x] `settingsIdleReadTimeoutMicros` in `Settings`; `handleClient`
         threads it; `StreamTimeout` answered with 408.
   - [x] Stalled-peer integration test (a partial request then silence
         yields a 408 within the bound, not a hang); `make check` green at
         18 integration examples.
   - [x] ADR-0027 accepted; noted in the network design document.

### Rollout Plan Escape Hatch

- If the timeout reaches behaviour this RFC does not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should a write/idle-send timeout follow for slow readers on the response
  path, and does it share `recvWithin`'s shape with `waitForWriteFD`?
- Is 30 s the right default, or should it be larger for slow upstreams and
  smaller for public exposure?
