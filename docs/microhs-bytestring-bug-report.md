# MicroHs ByteString Corruption Bug Report

This document is a bug report prepared for the MicroHs project. It is not a
MicroHttp design document; it records a runtime fault found while building the
network layer. The reproducers referenced here are retained under `spike/`.

> **Status (2026-06-12): no longer reproduces on the installed toolchain.**
> The MicroHs runtime now guards the `evalbytestring` walk against time-slice
> preemption (it saves `glob_slice`, raises it for the walk, and restores it),
> so `spike/MicroHttp/Spike11.hs` prints the correct lengths and concurrent
> serving is safe. The fix path matches the analysis below. This report is
> kept as the historical record and the upstream-facing write-up.

## Title

Silent ByteString corruption: `Data.ByteString.Char8.pack` of a large lazy
list yields an empty result after any `forkIO`.

## Environment

- MicroHs 0.16.0.0 (combinator file version v8.3).
- macOS arm64 (Darwin 25.5).
- Default time slice (`SLICE = 100000`).

## Summary

Once any other thread has been forked, even one that does nothing and has
already exited, forcing a sufficiently large lazily constructed `ByteString`
through `pack` yields an empty `ByteString`. The corrupt value is memoised, so
every later observer (`length`, `useAsCStringLen`, and so on) also sees zero.
Single-threaded, the same code is correct. The behaviour is deterministic
across runs on the machine above.

## Minimal Reproducer

No sockets and no FFI. This is `spike/MicroHttp/Spike11.hs` in the MicroHttp
repository.

```haskell
module Main (main) where

import Control.Concurrent (forkIO)
import qualified Data.ByteString.Char8 as BS

main :: IO ()
main = do
    _ <- forkIO (return ())
    print (BS.length (BS.pack (replicate 1000 'x')))   -- 1000 (correct)
    print (BS.length (BS.pack (replicate 5000 'y')))   -- 0 (want 5000)
```

Expected output:

```text
1000
5000
```

Observed output:

```text
1000
0
```

Deleting the `forkIO` line makes both lines correct. The size boundary on this
machine is between 1024 bytes (correct) and 4096 bytes (corrupt).

## User-Facing Function To Faulting Primitive

The chain from the called function to the faulting runtime case is fully
traced in the MicroHs sources:

- `Data.ByteString.Char8.pack = B.pack . map c2w` (`lib/Data/ByteString/Char8.hs`).
- `Data.ByteString.Internal.pack = primBSpack`, and
  `primBSpack = _primitive "bspack"` (`lib/Data/ByteString/Internal.hs`).
- `"bspack"` is `T_BSPACK` in the primitive table (`src/runtime/eval.c`).

The fault is therefore in the generic `[Word8] -> ByteString` path, not
anything Char8-specific. `c2w` maps each `Char` to a `Word8` lazily, and
`B.pack` walks that lazily produced `[Word8]` spine. Any `pack`-family call on
a large lazily built list is exposed.

## Root-Cause Analysis

Line numbers are from the 0.16.0.0 `src/runtime/eval.c`.

`T_BSPACK` overwrites its own argument with `combK` (Nil) for garbage
collection before it walks the list:

```c
case T_BSPACK:
    ...
    ARG(TOP(0)) = combK;                       /* the zap */
    struct bytestring rbs = evalbytestring(n); /* then walks the list */
```

`evalbytestring` forces each list cell via `evali`, re-entering the reduction
loop. The reduction loop decrements the time slice at the top
(`if (--glob_slice <= 0) yield();`). If the slice expires while the walk is in
progress and another thread is queued on the run queue, `yield()` reschedules
through `cleanup()` (which calls `CLEARSTK()`) and `longjmp(sched, ...)`. That
longjmp abandons the C stack frame of `evalbytestring` without unwinding it.

When the thread is later resumed, the runtime re-executes `T_BSPACK` from the
graph, as its scheduling model intends. But the argument node was already
overwritten with `combK`, so `evalbytestring` now sees Nil on its first
iteration and returns an empty `bytestring`, which `SETBSTR` memoises as the
result of the `pack`.

Single-threaded, `yield()` takes its documented "no other threads" path: it
resets the slice and returns without rescheduling, so the walk continues in
the same C frame and completes correctly. This is why the bug needs a prior
`forkIO`, and why a forked thread that has already exited still triggers it:
the child only needs to be on the run queue at the instant the slice expires
during the walk.

The size boundary follows from the same mechanism. A short walk is unlikely to
straddle a slice expiry; a long walk is increasingly likely to.

## Related Observations

These are factual observations about the existing source, recorded to help
diagnosis. They are not fix recommendations.

- `T_BSTOUTF8` contains the identical argument zap, but commented out, with the
  same "protected from GC by evalbytestring()" rationale. With the zap
  disabled, a mid-walk reschedule at that site re-executes correctly from the
  graph.
- `evalstring` carries a header comment that already notes the underlying
  hazard: "XXX this is cheating, should use continuations. XXX the malloc()ed
  string is leaked if we yield in here." The documented consequence there is a
  leaked buffer. The corruption in this report is a distinct consequence of the
  same frame abandonment, arising at the `T_BSPACK` site specifically because
  that site mutates its reachable argument before the walk completes.
- Userland retry does not reliably recover. A pure
  `pack`-then-check-length-then-retry loop with no effect between attempts can
  livelock: the corrupting condition is phase-locked to the reduction count, so
  a rebuilt-and-rewalked `pack` straddles the same slice expiry and corrupts
  again identically. Introducing any scheduling perturbation between attempts
  (an I/O action, a yield) shifts the phase and lets it converge, but a pure
  retry has no such perturbation.
- Unrelated minor: `hSetBuffering stdout NoBuffering` and `LineBuffering`
  appear to have no observable effect on a redirected, piped, or pty stdout.
  Output is flushed only on clean exit, so a killed hung run shows no stdout.
  `stderr` is write-through.

## Local Mitigation Applied

Pending an upstream decision, the MicroHttp developer's MicroHs runtime is
patched to make the list-walk primitives non-preemptible: `evalstring` and
`evalbytestring` in `src/runtime/eval.c` save `glob_slice`, set it to a large
value for the duration of the walk, and restore it afterwards. The walk
therefore completes without a reschedule, so the zapped argument is never
re-read. This trades latency for correctness. With the patch applied, both
reproducers below pass on every run, and they fail without it, so they serve
as the patch's regression check. This is a local stopgap, not a proposed fix;
the fix is the implementor's choice.

## Attachments

- `spike/MicroHttp/Spike11.hs`: the nine-line reproducer above.
- `spike/MicroHttp/Spike10.hs`: a socket-level manifestation. A non-blocking
  loopback sender is given length zero for its payload by the corrupt `pack`,
  sends nothing, and deadlocks with a receiver that polls `recv` forever. This
  is how the bug first presented, before minimisation.
