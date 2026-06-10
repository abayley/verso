# MicroHttp Network Design

This document describes the networking subsystem as it exists and the target
architecture it is moving toward. It spans `MicroHttp.Network.Socket` and
`MicroHttp.Server`, with touchpoints in `MicroHttp.Http.Parser` and
`MicroHttp.Http.Response`. The original per-module contracts are preserved in
`docs/initial-module-design/` and are not updated; this document is living.

Change plans referenced here:

- [RFC-0003](../rfcs/rfc-0003-socket-correctness-and-testability.md) covers
  request framing and socket testability.
- The readiness manager, performance harness, portability backends, and GHC
  support described under future direction do not have RFCs yet.

## Network Design Constraints

The design is shaped by the MicroHs runtime:

- Threads are green threads scheduled by the runtime on effectively one
  operating-system thread. A blocking syscall blocks every thread.
- There is no IO manager: no `threadWaitRead`, and no integration between
  file-descriptor readiness and the scheduler.
- STM is available (`TVar`, `TMVar`, `TQueue`, `TBQueue`, `atomically`,
  `retry`), as are `forkIO`, `MVar`, and `QSem`.

Consequences: every socket is set non-blocking, and every potentially
blocking operation is a retry loop that sleeps one millisecond on
`EAGAIN`/`EWOULDBLOCK`. Errors are returned as `Either SocketError`
(ADR-009), never thrown.

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
by a semaphore. Each connection serves exactly one request (ADR-011).

```mermaid
flowchart TD
    serve[serve: Settings + Application] --> listen[listenTcp]
    listen --> acceptLoop[accept: polls every 1 ms]
    acceptLoop --> fork[forkIO handler, QSem cap 32]
    fork --> acceptLoop
    fork --> recv[recv request bytes]
    recv --> parse[parseRequest with limits]
    parse --> app[Application: Request to IO Response]
    app --> write[writeResponse: sendAll chunks]
    write --> close[close client socket]
```

Known gap: the current implementation performs a single `recv` of at most
8192 bytes, so segmented or large requests are truncated and
`settingsMaxBodyBytes` is unreachable. RFC-0003 replaces the single read
with a framed reader that consumes chunks until the header terminator and
declared `Content-Length` are satisfied, enforcing limits incrementally.
The framed reader is also the intended chunk source for future streaming
request bodies.

## Concurrency Model

Current model: one green thread per connection, non-blocking syscalls, and
per-operation polling. Every waiting operation sleeps one millisecond and
retries its own syscall, so the syscall and wakeup cost scales with the
number of waiting sockets, and every wait has a latency floor of up to one
millisecond.

Target model: a single readiness manager replaces per-operation polling.

```mermaid
flowchart TD
    h1[Handler thread: recv would block] --> reg
    h2[Handler thread: send would block] --> reg
    h3[Accept loop: accept would block] --> reg
    reg[Readiness registry: fd, interest, TVar] --> poller
    poller[Single poller thread: one poll over all fds] --> kernel
    kernel[poll / kqueue / epoll / WSAPoll]
    poller -- flips readiness TVars --> reg
```

Waiting operations register their file descriptor and interest, then block
in `atomically` with `retry` on a readiness `TVar`; the poller performs one
`poll` over all registered descriptors and flips the `TVar`s of ready ones.
Because a blocking `poll` FFI call would stall the whole runtime, the first
poller still sleeps between zero-timeout polls; this preserves the latency
floor but reduces cost to one syscall and one sleeper per tick regardless of
socket count. If MicroHs later provides a way to block in an FFI call
without stalling the runtime, the same architecture becomes event-driven by
changing the poller's timeout.

The performance harness should be built before the readiness manager so the
polling tax is measured, not assumed.

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
