---
id: RFC-0007
name: Socket Portability (Linux and Windows)
status: Draft
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Socket Portability (Linux and Windows)

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-06-12 |
| Started   |            |
| Completed |            |

## Summary

Scope what it would take to run the socket adapter on Linux and on Windows,
which currently only works on macOS. Linux is a small, in-project change: one
platform-divergent piece (the `sockaddr_in` layout) plus an FFI integer-type
migration that is worth doing anyway. Windows is larger but viable in
userland: a Winsock adapter behind the existing interface, plus a delay-poll
readiness fallback (the runtime's poll queue is not configured on Windows,
but the scheduler is, so the pre-ADR-026 strategy still works). That ships
with a known cost -- the request/response latency floor returns on Windows --
which a contained runtime patch (`WSAPoll`) can later remove. This RFC
records the analysis and a phased plan; it does not implement anything.

## Context

`MicroHttp.Network.Socket` is the only module with platform-specific
assumptions, so the blast radius of portability work is one file (plus a
possible small C shim). The current code targets macOS. The facts below were
gathered from the code and the installed MicroHs runtime.

What is already portable:

- The constant imports (`AF_INET`, `SOCK_STREAM`, `SOL_SOCKET`,
  `SO_REUSEADDR`, `F_SETFL`, `O_NONBLOCK`) use `foreign import capi "... value
  X"`, which resolves each constant from the platform's headers at compile
  time. These self-adjust per OS.
- The retry-loop logic, the `Either SocketError` contract (ADR-009), the
  `ExceptT` plumbing (ADR-025), and the readiness waiting (ADR-026) are
  platform-neutral Haskell.

What is not portable, and why:

- The `sockaddr_in` byte layout. `encodeSockAddrIn` hardcodes the BSD form
  with a `sin_len` byte at offset 0: `[16, AF_INET, port_hi, port_lo, addr...,
  0x8]`. Linux and Windows have no `sin_len`; `sin_family` is a 16-bit field
  at offset 0, so the first two bytes `[16, 2]` are misread as family 528.
  This is the one Linux blocker.
- FFI integer types. The imports use `Int` for C `int` parameters and
  results (`c_socket`, `c_recv`, and so on). On LP64 macOS/Linux this happens
  to work for small values, but it is a latent width mismatch. RFC-0003
  explicitly deferred the `CInt`/`CSize`/`CSsize` migration to this RFC.
- The MicroHs runtime configuration. The unix runtime config defines
  `WANT_FD 1` and `WANT_IO_POLL 1` (Linux and macOS share it), so the
  readiness poll queue exists there. The `windows` and `mingw` runtime
  configs define neither, so on Windows `waitForReadFD` / `waitForWriteFD`
  take the no-poll fallback (return `-1`/`EINVAL`). The scope of this gap is
  narrower than it first appears, and the Windows section below works
  through it: the green-thread scheduler (`forkIO`, `threadDelay`, `yield`,
  MVars, `throwTo`) is in the runtime's unconditional token table, not
  behind any `WANT_` flag, so it runs on Windows; and the socket calls are
  this module's own `foreign import ccall`s, not the runtime's fd
  machinery, so they do not depend on `WANT_FD`/`WANT_IO_POLL` either. The
  one thing actually missing on Windows is the efficient readiness wait
  (`WANT_IO_POLL`), for which there is a userland fallback.
- The Windows socket API is Winsock: `WSAStartup` is required, sockets are
  `SOCKET` (a `UINT_PTR`, not `int`, so 64-bit on Win64), `close` is
  `closesocket`, non-blocking is `ioctlsocket(FIONBIO)` not
  `fcntl(O_NONBLOCK)`, and errors come from `WSAGetLastError` not `errno`.

## Goals

- A clear, evidence-based account of the Linux and Windows gaps, each with
  its required changes and where they live (in-project versus upstream
  MicroHs).
- A phased plan that lands the cheap, broadly useful work first (the FFI
  type migration, then Linux) and isolates the large, partly-upstream
  Windows work behind the same module interface.
- A single platform seam, so callers and the rest of the server never see
  per-platform code.

## Non-Goals

- No implementation in this RFC; it is a scoping document.
- No commitment to ship Windows support now; the analysis shows it is
  feasible in userland, but with a performance cost until the runtime
  `WSAPoll` patch lands.
- No change to the public socket interface or the `Either` contract.
- No new concurrency model; ADR-011 and ADR-026 stand.

## Proposal

The work splits into three slices, each its own future RFC or phase.

### FFI integer-type migration (prerequisite, in-project)

Migrate the socket FFI from `Int` to the correct C types: `CInt` for
descriptors and `int` parameters, `CSize`/`CSsize` for the `recv`/`send`
lengths and results, and the `socklen_t` pointer in `accept`/`getsockname`.
Convert at the module boundary so the public types (`ClientSocket`,
`Int`-sized byte counts) are unchanged. This fixes the latent width mismatch
on every platform, is independent of the layout work, and is the natural
place to make the descriptor newtype able to hold a Windows `SOCKET` later
(a wider type than `CInt`). Low risk, covered by the existing socket
integration suite.

### Linux (small, in-project)

Replace the hand-built BSD `sockaddr_in` with a platform-correct
construction. Per ADR-007, a C helper is the sanctioned fallback once
Haskell-side layout hits a portability problem; the options are:

- a tiny C shim `mk_sockaddr_in(port, addr, out)` that the platform headers
  define correctly, called through one FFI import; or
- building the address with `getaddrinfo` / `inet_pton` and `memcpy`, so the
  libc owns the layout; or
- conditional Haskell (`#if defined(darwin_HOST_OS)` versus else) if MicroHs
  supports CPP, with the BSD and no-`sin_len` layouts side by side.

The C-shim option is recommended: it is ADR-007's intended path, sidesteps
the open question of MicroHs CPP support, and is the smallest correct change.
Linux otherwise carries over unchanged: the unix runtime already provides
`WANT_FD` and `WANT_IO_POLL`, so framing, the readiness manager, and the idle
timeout all work. After this slice plus the type migration, Linux should run
the full integration suite.

### Windows (large, but viable in userland)

Windows needs a Winsock adapter behind the existing interface. Behind
`MicroHttp.Network.Socket`: call `WSAStartup` once at startup; link `ws2_32`;
use `closesocket`; set non-blocking with `ioctlsocket(FIONBIO)`; read errors
via `WSAGetLastError` and map `WSAEWOULDBLOCK`/`WSAEINPROGRESS`; widen the
descriptor newtype to a `SOCKET`-sized type (the FFI type migration above is
where this lands); and supply the Windows `sockaddr_in` (same no-`sin_len`
layout as Linux, so the Linux helper is reusable). The toolchain question --
does `mhs` build and run a socket server on Windows at all -- should be
answered before committing to the adapter.

The readiness gap looks like it blocks Windows but does not, because the
scheduler is intact. `forkIO`, `threadDelay`, `yield`, MVars, and `throwTo`
are in the runtime's unconditional token table, so the cooperative
concurrency model runs on Windows; only the `WANT_IO_POLL` readiness
primitive is missing. That gives a userland fallback that needs no runtime
recompile.

#### Userland readiness fallback

Make the readiness wait a seam with a per-platform implementation:

- POSIX: `waitForReadFD` / `waitForWriteFD` (the ADR-026 runtime poll queue).
- Windows: the pre-ADR-026 strategy -- a non-blocking socket
  (`ioctlsocket(FIONBIO)`) plus `threadDelay` between retries. This works
  because `threadDelay` is core/ungated.

Consequences of the Windows fallback:

- Correctness is identical on both platforms.
- Bulk throughput is unaffected: under saturation reads rarely block, so the
  fallback rarely sleeps. The saturated and egress bench figures should hold
  on Windows.
- The request/response latency floor returns, on Windows only: each idle wait
  pays a `threadDelay` tick, so the ping-pong figure drops back toward the
  pre-ADR-026 ~50 MB/s ceiling.
- The idle read timeout (RFC-0006) still works, and more simply: the
  delay-poll loop already wakes every tick, so it checks elapsed-against-
  deadline per tick rather than relying on `System.Timeout` interrupting a
  parked wait.

A `yield`-then-`threadDelay` hybrid softens the floor: `yield` a few times
(cooperative, no sleep, lets other handlers run at near-zero latency) before
falling back to `threadDelay` when genuinely idle, so the sleep penalty is
paid only when there is no other work and CPU stays bounded.

The floor cannot be removed in pure userland on this single-OS-thread
runtime: any blocking wait (`recv`, `WSAPoll` with a non-zero timeout)
freezes every green thread, and the only thing allowed to block on many
descriptors at once is the runtime's own poll queue, which is what is
missing. A userland poller thread would have to call `WSAPoll` with a zero
timeout in a loop and `yield`/`threadDelay` between passes -- one syscall per
tick instead of one per waiter, but the same latency floor. So the delay-poll
is the best userland option.

#### The performant fix (not userland)

Patch the runtime's `check_pollq` to use `WSAPoll` instead of `poll()` and
enable `WANT_IO_POLL` on the Windows target. The two APIs are nearly
identical, so this is a contained runtime change, and it restores ADR-026
performance on Windows. It is a MicroHs recompile, not userland, and is the
right long-term answer.

Recommendation: do the type migration and Linux first to prove the seam on a
second platform. Windows is then a userland adapter (Winsock plus the
delay-poll fallback) shippable with a known, bounded cost -- the
request/response latency floor -- which the `WSAPoll` runtime patch can later
remove.

## Alternatives Considered

- Keep hand-encoding `sockaddr_in` with per-platform byte tables in Haskell:
  brittle, re-derives what the headers already define, and still needs the
  layout branch. The C helper is simpler and authoritative.
- Expecting userland Windows to match POSIX readiness performance: not
  possible on the single-OS-thread runtime without the poll queue, so the
  delay-poll latency floor is accepted as the Windows cost until the runtime
  `WSAPoll` patch removes it. Shipping the fallback is the chosen path, not a
  rejected one; what is rejected is pretending userland can avoid the floor.

## Security Impact

- None directly; portability does not change parsing, limits, or timeouts.
- The Windows delay-poll fallback reintroduces the latency floor ADR-026
  removed, but only on Windows and only for request/response turnaround; the
  idle read timeout (RFC-0006) still bounds slow peers there.

## Reliability Impact

- The FFI type migration removes a latent width mismatch on all platforms.
- Per-platform behaviour differences (notably Windows readiness) must be
  documented so operators know the performance and timeout characteristics
  differ by OS.

## Testing and Quality Gates

- The existing loopback integration suite is the portability safety net
  RFC-0003 built it to be; it should pass unchanged on each newly supported
  platform.
- Running the suite per platform needs CI on that platform; today everything
  is exercised on macOS only.

### Verifying performance on a new platform

The `bench/` suite (also in the README) is how to check whether a port keeps
up, and in particular how the Windows delay-poll fallback compares. The
targets, what each measures, and what to expect on Windows:

- `make bench-socket` -- single-threaded ping-pong over loopback, MB/s per
  recv buffer size. This is the figure the readiness wait drives: ~1-1.5 GB/s
  on POSIX (ADR-026), but expected to drop toward the pre-ADR-026 ~50 MB/s on
  the Windows delay-poll fallback. The `yield`-then-`threadDelay` hybrid
  should be measured here to see how much of the floor it recovers.
- `make bench-socket-saturated` -- a GHC blocking sender keeps the pipe full
  while the MicroHs receiver drains it; reports the raw `recv` ceiling.
  Expected to be roughly platform-independent (reads rarely block, so the
  fallback rarely sleeps).
- `make bench-iteratee` -- plain `recv` versus `socketEnumerator` into a
  counting consumer, same harness; the delta is the iteratee overhead, which
  should stay small on any platform.
- `make bench-egress` -- plain `sendAll` versus `socketSinkI`, with a GHC
  drainer keeping the pipe empty; the send-path counterpart.

The saturated, iteratee, and egress benches use a GHC sender/drainer built
with Cabal and the `network` package (Winsock-backed on Windows), so the
two-process harness itself is portable. The expected Windows signature is:
bulk benches comparable to POSIX, `bench-socket` ping-pong floored by the
delay-poll until the `WSAPoll` runtime patch lands. Recording before/after
numbers for the hybrid and the patch is how the floor's cost and recovery
get quantified.

## Rollout Plan

1. FFI integer-type migration (in-project, all platforms).
2. Linux: platform-correct `sockaddr_in`; run the integration suite on
   Linux.
3. Windows: the Winsock adapter behind the existing interface, with the
   delay-poll readiness fallback (and optionally the `yield`-then-sleep
   hybrid); run the integration suite and the benches to record the cost.
4. Windows performance: the runtime `WSAPoll`/`WANT_IO_POLL` patch to remove
   the delay-poll floor; re-run the benches to confirm.

Each slice is a candidate for its own RFC when picked up; this document is
the umbrella analysis.

## Open Questions

- Does `mhs` build and run a socket server on Windows today? (The userland
  path needs only the scheduler and the FFI, not `WANT_IO_POLL`.)
- Is enabling a `WSAPoll`-backed poll queue on the Windows runtime on the
  upstream roadmap, or should this project carry the patch for the
  performant variant?
- Does MicroHs support CPP, in case conditional Haskell is preferred over a C
  shim for the layout?
- Should the descriptor newtype move to a `CIntPtr`/`SOCKET`-sized type as
  part of the migration, so Windows needs no further type change?
- Is there CI capacity to run the integration suite on Linux (and later
  Windows), without which portability claims are unverified?
