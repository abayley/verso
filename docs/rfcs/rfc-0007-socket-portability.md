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
migration that is worth doing anyway. Windows is a much larger effort that is
partly upstream: the MicroHs runtime as configured does not compile in
file-descriptor IO or the poll queue on its Windows targets, and the socket
API is Winsock, not POSIX. This RFC records the analysis and a phased plan;
it does not implement anything.

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
  `WANT_FD 1` and `WANT_IO_POLL 1` (Linux and macOS share it), so descriptor
  IO and the readiness poll queue exist there. The `windows` and `mingw`
  runtime configs define neither: on Windows the runtime does not currently
  compile in file-descriptor IO or the poll queue, so `waitForReadFD` /
  `waitForWriteFD` take the no-poll fallback (return `-1`/`EINVAL`).
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
- No commitment to ship Windows support; it may prove gated on upstream
  MicroHs runtime work.
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

### Windows (large, partly upstream)

Windows needs a Winsock adapter behind the existing interface and, first,
runtime support that is not currently configured:

- Upstream MicroHs: the `windows`/`mingw` runtime targets would need
  descriptor IO and a readiness mechanism. The poll queue uses POSIX
  `poll()`; Windows has `WSAPoll`, so either the runtime grows a Windows
  readiness path or the adapter falls back to the pre-ADR-026 delay-poll on
  Windows only. This is the gating decision and is outside MicroHttp.
- In MicroHttp, behind `MicroHttp.Network.Socket`: call `WSAStartup` once at
  startup; link `ws2_32`; use `closesocket`; set non-blocking with
  `ioctlsocket(FIONBIO)`; read errors via `WSAGetLastError` and map
  `WSAEWOULDBLOCK`/`WSAEINPROGRESS`; widen the descriptor newtype to a
  `SOCKET`-sized type; and supply the Windows `sockaddr_in` (same
  no-`sin_len` layout as Linux, so the Linux helper is reusable).
- Toolchain: confirm `mhs` builds and runs a socket server on Windows at all
  before committing to the adapter.

Because so much of Windows is upstream or unknown, the recommendation is to
do the type migration and Linux first, prove the seam on a second platform,
and treat Windows as a separate decision once MicroHs runtime support is
clearer.

## Alternatives Considered

- Keep hand-encoding `sockaddr_in` with per-platform byte tables in Haskell:
  brittle, re-derives what the headers already define, and still needs the
  layout branch. The C helper is simpler and authoritative.
- A pure-Haskell Winsock binding with no runtime changes: cannot provide
  non-busy readiness on Windows without the runtime's poll queue, so it would
  reintroduce the delay-poll the benches showed is the bottleneck.

## Security Impact

- None directly; portability does not change parsing, limits, or timeouts.
- A Windows delay-poll fallback (if chosen) would reintroduce the latency
  floor ADR-026 removed, but only on Windows.

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

## Rollout Plan

1. FFI integer-type migration (in-project, all platforms).
2. Linux: platform-correct `sockaddr_in`; run the integration suite on
   Linux.
3. Windows: gated on a MicroHs runtime decision for descriptor IO and
   readiness; then the Winsock adapter behind the existing interface.

Each slice is a candidate for its own RFC when picked up; this document is
the umbrella analysis.

## Open Questions

- Does `mhs` build and run a socket server on Windows today, and is enabling
  `WANT_FD`/`WANT_IO_POLL` (or a `WSAPoll` equivalent) on the Windows runtime
  on the upstream roadmap?
- Does MicroHs support CPP, in case conditional Haskell is preferred over a C
  shim for the layout?
- Should the descriptor newtype move to a `CIntPtr`/`SOCKET`-sized type as
  part of the migration, so Windows needs no further type change?
- Is there CI capacity to run the integration suite on Linux (and later
  Windows), without which portability claims are unverified?
