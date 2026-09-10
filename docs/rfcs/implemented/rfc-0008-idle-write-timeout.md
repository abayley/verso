---
id: RFC-0008
name: Idle Write Timeout
status: Implemented
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Idle Write Timeout

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-06-12            |
| Started   | 2026-06-12 17:58 NZST |
| Completed | 2026-06-12 17:58 NZST |

## Summary

Bound how long the server waits when a slow or stalled reader stops draining
the response. This is the mirror of RFC-0006: when a `sendAll` would block
because the kernel send buffer is full and the peer is not reading, the
write-readiness wait is given a deadline. If the peer does not drain within
`settingsIdleWriteTimeoutMicros`, the write fails and the connection closes.
The bound is on the idle wait, not on each write, so a write that has buffer
space returns immediately with no timer; a timer is armed only when the write
would actually block. This frees a handler and its active-handler slot from a
slow reader, closing the last unbounded wait on a connection.

## Context

RFC-0006 closed the slow-sender hole on the read path: a peer that opens a
connection and then sends nothing (or dribbles a partial request) can no
longer hold a handler thread, because the idle read wait has a deadline. The
symmetric hole remains on the write path. After the application produces a
response, the server writes it with `sendAll`; if the client stops reading,
the kernel send buffer fills, `sendAll` hits `EAGAIN`, parks on
`waitForWriteFD` (RFC-0005), and waits indefinitely. The handler thread and
its `settingsMaxActiveHandlers` slot are held for as long as the slow reader
chooses, which is the same resource-exhaustion vector RFC-0006 addressed,
just in the other direction.

The mechanism is already proven. RFC-0005 uses `waitForWriteFD` for the
`sendAll` and `connectTcp` would-block paths on POSIX, so write readiness
works. RFC-0006 showed `timeout` interrupts a thread parked in
`waitForReadFD`; `waitForWriteFD` parks on the same runtime poll queue, and
the runtime's `thread_intr` unlinks a parked thread regardless of whether it
waits for read or write, so the same fork-based `timeout` reaches it. The
`forkIO`/`System.Timeout` safety established in RFC-0006 (the ByteString
corruption bug no longer reproduces) carries over unchanged.

One difference from the read side shapes the design: a write timeout happens
after the response head may already be on the wire, so the server cannot
answer with a status code (there is no 408 equivalent). The only correct
action is to fail the write and close the connection, which the existing
`ServerWriteFailed` path already does.

## Goals

- A slow or stalled reader cannot hold a handler thread (and an active
  handler slot) indefinitely while the server writes a response.
- The bound is on the idle wait, so it adds no per-write cost when the peer
  is draining and arms a timer only when a write would block.
- Disabled by a non-positive setting, preserving the previous behaviour
  exactly.
- The public socket interface keeps its `Either` error contract (ADR-0009),
  and the change reuses RFC-0006's shape (`sendAllWithin` mirroring
  `recvWithin`).

## Non-Goals

- No status-code response on a write timeout; the head may already be sent,
  so the connection just closes.
- No total-response-time budget; the bound is per idle write wait.
- No change to the read timeout, the readiness manager, or the concurrency
  model.

## Proposal

- `Settings` gains `settingsIdleWriteTimeoutMicros :: Int`; `<= 0` disables
  it. `defaultSettings` sets 30 s, matching the read timeout.
- `MicroHttp.Network.Socket` gains
  `sendAllWithin :: Int -> ClientSocket -> BS.ByteString -> IO (Either
  SocketError ())`, the idle timeout as the first argument; `sendAll =
  sendAllWithin 0` keeps the existing signature and callers. When a `sendAll`
  would block, `sendAllWithin` waits for write readiness bounded by the
  timeout: disabled means the RFC-0005 indefinite `waitForWriteFD`;
  otherwise `timeout n (waitForWriteFD fd)`, and a `Nothing` (deadline
  reached) returns `Left (SocketError "send" eTIMEDOUT)`. `isTimeoutError`
  already identifies it.
- `MicroHttp.Server`: the response writer (`socketResponseWriter`) uses
  `sendAllWithin (settingsIdleWriteTimeoutMicros settings)`. Because both the
  strict-body head-plus-body write and the streaming-body write go through
  that one writer (the `StreamBody` path drives `byteSinkI writer`), bounding
  `socketResponseWriter` bounds every write. A timed-out write surfaces as
  the existing `ServerWriteFailed` (the connection is closed in
  `handleClient` regardless), so no new error case or response is needed.

The write timeout covers the response head and the body, including a
streaming `StreamBody`, because all of them are written through the same
bounded writer.

Optional, for symmetry and the bench/general path: `socketSinkI` could grow
a timeout variant the same way, but it is not on the server response path and
is not required for this RFC's goal.

## Alternatives Considered

- Timeout around the whole response write: a total-response budget rather
  than an idle bound, so a peer draining one byte per interval under the
  budget still stalls a handler for the whole budget. The idle bound is the
  standard slow-reader guard, matching RFC-0006.
- A new error case and a status response: impossible once the head is sent,
  and unnecessary -- closing on `ServerWriteFailed` is the correct outcome.

## Security Impact

- Closes the slow-reader resource-exhaustion vector, the write-path mirror
  of RFC-0006. With both timeouts, neither a slow sender nor a slow reader
  can hold a handler slot indefinitely.
- The default becomes a finite 30 s write wait rather than indefinite; an
  operator can disable it with `<= 0`.

## Reliability Impact

- A timer thread is forked only when a write would block, so a draining peer
  is unaffected and the egress benches should be unchanged.
- A timed-out write closes the connection, freeing the QSem slot, exactly as
  a transport write failure already does.

## Testing and Quality Gates

- `make check` stays green; the existing suite confirms normal responses are
  unaffected (clients drain well within 30 s).
- New integration test: a client sends a request then stops reading while the
  server returns a response large enough to overflow the kernel send buffer;
  with a short idle write timeout, `handleClient` returns a write failure
  within the bound rather than hanging. This also verifies that `timeout`
  interrupts a poll-queue-parked write in the server path. As in RFC-0006, a
  strict red-first test is impractical (the pre-feature behaviour is a hang),
  so the test is added with the implementation and depends on the feature.

## Rollout Plan

1. Phase one: idle write timeout.
   - [x] `sendAllWithin` in `MicroHttp.Network.Socket`; `sendAll =
         sendAllWithin 0`.
   - [x] `settingsIdleWriteTimeoutMicros` in `Settings`;
         `socketResponseWriter` threads it.
   - [x] Stalled-reader integration test (a large response to a non-reading
         client fails within the bound, not a hang); `make check` green.
   - [x] Flip ADR-0028 to accepted; note it in the network design document.

### Rollout Plan Escape Hatch

- If the timeout reaches behaviour this RFC does not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should `socketSinkI` also gain a timeout variant for symmetry and the
  general egress path, or is bounding `socketResponseWriter` enough until a
  non-server `socketSinkI` user appears?
  - Resolved: deferred. `socketSinkI` is not on the server response path, so
    bounding `socketResponseWriter` meets this RFC's goal. A timeout variant
    is added when a non-server `socketSinkI` user appears.
- Should the read and write idle timeouts share one
  `settingsIdleTimeoutMicros`, or stay separate so they can be tuned
  independently (a server may tolerate slow readers differently from slow
  senders)?
  - Resolved: separate. `settingsIdleReadTimeoutMicros` and
    `settingsIdleWriteTimeoutMicros` stay distinct so a server can tolerate
    slow readers and slow senders differently; both default to 30 s.
