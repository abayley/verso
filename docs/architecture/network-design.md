# MicroHttp Network Design

This document describes the networking subsystem as it exists and the target
architecture it is moving toward. It spans `MicroHttp.Network.Socket` and
`MicroHttp.Server`, with touchpoints in `MicroHttp.Http.Parser` and
`MicroHttp.Http.Response`. The original per-module contracts are preserved in
`docs/architecture/initial-module-design/` and are not updated; this document is living.

Change plans referenced here:

- [RFC-0003](../rfcs/implemented/rfc-0003-socket-correctness-and-testability.md) covers
  request framing and socket testability.
- [RFC-0005](../rfcs/implemented/rfc-0005-socket-readiness-manager.md) covers socket
  readiness waiting (replacing the 1 ms poll with the runtime poll queue).
- Portability backends and GHC support described under future direction do
  not have RFCs yet; the performance harness is the `bench/` suite.

## Network Design Constraints

The design is shaped by the MicroHs runtime:

- Threads are green threads scheduled by the runtime on effectively one
  operating-system thread. A blocking syscall blocks every thread.
- The runtime does, however, have a `poll()`-based I/O wait queue in its
  scheduler, exposed as `waitForReadFD`/`waitForWriteFD`
  (`IO.waitrdfd`/`IO.waitwrfd`, under `WANT_IO_POLL`). This is the
  integration between file-descriptor readiness and the scheduler that
  earlier drafts of this document assumed was absent; RFC-0005 uses it.
- STM is available (`TVar`, `TMVar`, `TQueue`, `TBQueue`, `atomically`,
  `retry`), as are `forkIO`, `MVar`, and `QSem`.

Consequences: every socket is set non-blocking, and every potentially
blocking operation is a retry loop. On `EAGAIN`/`EWOULDBLOCK` it parks the
thread on the runtime poll queue (RFC-0005) rather than sleeping. Errors are
returned as `Either SocketError` (ADR-0009), never thrown.

## Listening Socket State Machine

`listenTcp` walks a fixed syscall pipeline. Failure at any step closes the
file descriptor and returns the failing operation's name and errno.

```mermaid
stateDiagram-v2
    [*] --> Created: socket(AF_INET, SOCK_STREAM)
    Created --> Reusable: setsockopt(SO_REUSEADDR)
    Reusable --> Bound: bind(sockaddr_in)
    Bound --> Listening: listen(backlog)
    Listening --> NonBlocking: fcntl(O_NONBLOCK)
    NonBlocking --> [*]: Right ListenSocket
    Created --> Failed: error
    Reusable --> Failed: error
    Bound --> Failed: error
    Listening --> Failed: error
    NonBlocking --> Failed: error
    Failed --> [*]: close(fd), Left SocketError
```

The bind address is a hand-built sixteen-byte `sockaddr_in`. The current
layout is the BSD form with a length byte at offset zero, which is correct
on macOS only; Linux puts a sixteen-bit family at offset zero. RFC-0003
extracts this encoding as a pure function so per-platform layouts become a
unit-tested seam.

## Request Lifecycle

`serve` accepts in a loop and forks one green thread per connection, capped
by a semaphore. Each connection serves exactly one request (ADR-0011).

```mermaid
flowchart TD
    serve[serve: Settings + Application] --> listen[listenTcp]
    listen --> acceptLoop[accept: parks on read readiness]
    acceptLoop --> fork[forkIO handler, QSem cap 32]
    fork --> acceptLoop
    fork --> recv[recv request bytes]
    recv --> parse[parseRequest with limits]
    parse --> app[Application: Request to IO Response]
    app --> write[writeResponse: sendAll chunks]
    write --> close[close client socket]
```

`handleClient` frames the request with `MicroHttp.Http.Framing.frameRequest`
(RFC-0003, ADR-0023): it consumes `recv` chunks until the header terminator
and declared `Content-Length` are satisfied, enforcing the header and body
limits incrementally. A complete request is dispatched to the application; a
framing limit or completeness failure is answered with a 400, matching the
parser's malformed-request handling; a transport failure is reported as
`ServerReadFailed`. This replaced an earlier single `recv` that truncated
segmented or large requests and left `settingsMaxBodyBytes` unreachable. The
framed reader is also the intended chunk source for future streaming request
bodies.

## Concurrency Model

One green thread per connection, non-blocking syscalls, and a would-block
retry loop per operation. The original design slept one millisecond on
`EAGAIN`/`EWOULDBLOCK` before retrying, which the post-RFC-0004 benches
showed caps request/response turnaround at ~50 MB/s against a ~2.3 GB/s
saturated ceiling: each wait paid up to a millisecond of latency floor.

RFC-0005 (ADR-0026) removed that floor without building a bespoke poller.
The MicroHs runtime is already the single poller: its scheduler maintains a
`poll()`-based I/O wait queue, and `waitForReadFD`/`waitForWriteFD`
(`IO.waitrdfd`/`IO.waitwrfd`, enabled by `WANT_IO_POLL`) park the current
green thread on it until the descriptor is ready.

```mermaid
flowchart TD
    h1[Handler thread: recv would block] --> wait
    h2[Handler thread: send would block] --> wait
    h3[Accept loop: accept would block] --> wait
    wait[waitForReadFD / waitForWriteFD: park on the runtime poll queue] --> sched
    sched[Runtime scheduler: one poll over all parked fds] --> kernel
    kernel[poll]
    sched -- wakes the ready thread --> h1
```

On a would-block result the operation parks via `waitForReadFD` (`recv`,
`accept`) or `waitForWriteFD` (`sendAll`, `connectTcp`) and retries when the
scheduler wakes it. No operation blocks in a syscall, so the single-OS-thread
runtime is preserved; only the scheduler blocks, in one `poll()` over every
parked descriptor at once. The ping-pong bench rose from ~50 MB/s to
~1.0-1.5 GB/s after the change. The runtime's `MAX_POLL_FDS` (100) bounds
simultaneously-waiting descriptors, so it and `settingsMaxActiveHandlers`
(32) should stay consistent.

RFC-0006 (ADR-0027) bounds the read-side wait: when a request `recv` would
block, the park is given a deadline (`timeout n (waitForReadFD fd)`) of
`settingsIdleReadTimeoutMicros` (30 s by default, non-positive disables).
A reached deadline surfaces as `StreamTimeout` and the server answers
`408 Request Timeout`, so a stalled peer cannot hold a handler slot
indefinitely. The timer is armed only on a would-block read, so steady
transfers keep the throughput above.

RFC-0008 (ADR-0028) mirrors this on the write side: when a response `sendAll`
would block because a slow reader has stopped draining and the kernel send
buffer is full, the park is given a deadline (`timeout n (waitForWriteFD fd)`)
of `settingsIdleWriteTimeoutMicros` (30 s by default, non-positive disables).
`sendAll = sendAllWithin 0`. A reached deadline closes the connection through
the existing `ServerWriteFailed` path -- there is no status answer, since the
head may already be on the wire. The server's single `socketResponseWriter`
carries both strict and streaming bodies, so threading the timeout through it
bounds every write. As on the read side the timer is armed only on a
would-block write, so a draining peer keeps the throughput above.

RFC-0009 introduced an opt-in access log; RFC-0012 (ADR-0032, superseding
ADR-0029) then reshaped the contracts so it is an ordinary middleware. The
`Application` now consumes the raw request stream and receives the connection's
peer (`ConnectionInfo`), so `logRequests` -- the outermost middleware -- taps
the first line for the method and target, holds the peer, times the request,
counts the request bytes, and emits a `RQST` line on the first line and a
terminal `RESP`/`ABRT` line. Framing moved out of the server into
`Router.serveRoutes` (the bottom of the application stack), the 400/408
responses into the `withErrorResponses` middleware, and `handleClient`
collapsed to driving the stack, writing the response, and closing. The logger
is the injected sink-and-formatter component from `MicroHttp.Log`; the
application composes it, so logging is off unless composed in.

The performance harness should be built before the readiness manager so the
polling tax is measured, not assumed.

Known runtime finding: under MicroHs 0.16.0.0 (macOS arm64), forcing a
sufficiently large lazily constructed ByteString yields an empty value
once any other thread has been forked, even a thread that did nothing and
has already exited. The corrupt value is memoised, and every forcing
observer is affected (`BS.length` and `useAsCStringLen` both tested). The
boundary sits between 1024 bytes (correct) and 4096 bytes (corrupt).
`spike/MicroHttp/Spike11.hs` is a nine-line deterministic reproducer;
`spike/MicroHttp/Spike10.hs` preserves the socket-level manifestation it
was minimised from, where a sender received length zero for its payload,
sent nothing, and deadlocked with its polling receiver. `packCStringLen`
from FFI buffers, as used by `recv`, round-trips real bytes in the
loopback suite and appears unaffected.

No validated in-process userland workaround is known. Two earlier
candidates were withdrawn on closer testing: copying the bytes out under a
brief `useAsCStringLen` only masked the fault in the experiment that
appeared to validate it, and a pure pack-then-check-length-then-retry loop
can livelock, because the corrupting condition is phase-locked to the
reduction count, so a rebuilt-and-rewalked pack straddles the same slice
expiry and corrupts identically unless a scheduling perturbation is
introduced between attempts (which a pure function cannot do). The root
cause and the full diagnosis are in
[microhs-bytestring-bug-report.md](../reviews/microhs-bytestring-bug-report.md).

Current local mitigation: the MicroHs runtime is patched to make the
ByteString list-walk primitives non-preemptible. In
`src/runtime/eval.c`, `evalstring` and `evalbytestring` save `glob_slice`,
inflate it for the duration of the walk, and restore it afterwards, so the
walk cannot be rescheduled mid-flight and the zapped-argument re-execution
never happens. This trades latency (a large pack now runs without yielding)
for correctness, which is the accepted trade until upstream resolves it.
The patch lives in the developer's MicroHs checkout and its installed
mcabal copy, not in this repository; it must be reapplied after any MicroHs
reinstall. `spike/MicroHttp/Spike11.hs` and `spike/MicroHttp/Spike10.hs`
both pass under the patch and both fail without it, so they double as the
patch's regression check. Integration tests keep their single-threaded
transfer rounds for now; the readiness manager and performance harness work
should retest concurrency once upstream resolves the bug and the local
patch is dropped.

## Streaming Direction

Request and response bodies move to the iteratee and enumerator model per
[RFC-0004](../rfcs/implemented/rfc-0004-iteratee-streaming-io.md) and ADR-0024:
producers (socket, file, strict value) are enumerators, consumers (framing,
handlers, the socket sink) are iteratees, and stream transformations such
as the Content-Length bound are enumeratees. Residual input lives in the
consumer's result and flows forward through monadic bind, so no producer
pushback exists; memory is bounded by chunk and header limits, never by
message size. The ingress pipeline is socket enumerator, header framing,
ingress enumeratees, then the handler iteratee; the egress pipeline is the
body enumerator, egress enumeratees, then the socket sink. Middleware
keeps its `Application -> Application` shape, with stream-touching
middleware lifting enumeratees onto one of the two pipelines.

## Portability Direction

Target platforms are macOS, Linux, and Windows.

- macOS and Linux differ only in the `sockaddr_in` layout and minor errno
  values; the pure encoder from RFC-0003 is the seam.
- Windows is a separate backend: Winsock startup, `SOCKET` handles,
  `closesocket`, `ioctlsocket(FIONBIO)` instead of `fcntl`, `WSAPoll`, and
  `WSAGetLastError` instead of errno.
- Divergence should live in compiler- or platform-specific module
  directories selected by include path, following the existing
  `test/ghc-compat/` pattern, rather than CPP.

## GHC Compatibility Direction

GHC is currently a coverage tool only: `make coverage` compiles `src/` and
the test suites with GHC and HPC. The server binary has never been built or
run under GHC. Elevating GHC to a supported platform requires:

- Migrating FFI signatures from `Int` to `Foreign.C.Types` (`CInt`,
  `CSize`): GHC's code generator does not guarantee the upper half of a
  64-bit read from a C `int` return. Both compilers provide
  `Foreign.C.Types`.
- Using `capi` for function imports as well as constants, which makes GHC
  check prototypes against headers and handles the variadic `fcntl`
  correctly.
- A `check-ghc` gate that builds and runs the suites, and a GHC build of the
  TestApp exercised by the browser smoke flow.

GHC support and OS portability share their seams: GHC runs on Linux and
Windows today, so a first-class GHC target provides CI coverage of all
compiler-independent code before MicroHs is proven on those platforms.

## Network Testing Strategy

- Pure units: sockaddr encoding, request framing over a scripted chunk
  source, `isWouldBlock` classification.
- Loopback integration: `connectTcp` plus `boundPort` (RFC-0003) enable
  in-process accept, round-trip, partial-send, peer-close, and error-mapping
  tests against real sockets on port zero.
- End to end: the TestApp browser smoke flow, and a future performance
  harness recording requests per second and latency percentiles under
  concurrent load.
