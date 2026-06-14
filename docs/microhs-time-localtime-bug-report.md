# MicroHs `time` Package Local-Time Offset Bug Report

This document is a bug report prepared for the MicroHs project. It is not a
MicroHttp design document; it records a fault found while adding local-time
timestamps to the access log. It is the reason `MicroHttp.Log.localTimestamp`
uses a direct `localtime`/`strftime` FFI rather than `Data.Time`.

> **Status (2026-06-14): open on the installed toolchain.** Left as-is for now.
> The fault is in how the bundled `time` package is configured for the MicroHs
> build, so a newer compiler / package port may resolve it; re-test `Data.Time`
> local-time conversion when the toolchain updates, and if it is correct, the
> FFI in `MicroHttp.Log` can be replaced.

## Title

`Data.Time.getZonedTime` / `getCurrentTimeZone` return the local UTC offset with
the wrong sign under MicroHs, so local times are computed with a negated offset
(and the wrong calendar day for zones far from UTC). The zone name is correct.

## Environment

- MicroHs 0.16.0.0, `time-1.15` (as installed under `~/.mcabal`).
- macOS arm64 (Darwin 25.5), system zone `Pacific/Auckland` (NZST, UTC+12).

## Summary

`getCurrentTimeZone` reports the correct zone *name* but a UTC offset of the
wrong sign: `NZST` (which is UTC+12) is returned as `-1200` rather than `+1200`.
`getZonedTime` therefore renders local time by *subtracting* the offset instead
of adding it, producing both the wrong clock time and, near a day boundary, the
wrong date. The bug is platform-configuration driven and deterministic.

## Minimal Reproducer

```haskell
module Main (main) where

import Data.Time (getCurrentTime, getCurrentTimeZone, getZonedTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

main :: IO ()
main = do
    utc <- getCurrentTime
    tz <- getCurrentTimeZone
    zt <- getZonedTime
    putStrLn ("UTC      : " ++ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%z" utc)
    putStrLn ("zone     : " ++ show tz)
    putStrLn ("ZonedTime: " ++ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%z" zt)
```

Observed (system zone NZST, UTC+12), at one instant:

```text
UTC      : 2026-06-14T19:47:47+0000
zone     : NZST
ZonedTime: 2026-06-14T07:47:47-1200
```

Expected: for UTC `19:47` on the 14th, NZST local is `07:47` on the **15th** at
**+1200**, i.e. `2026-06-15T07:47:47+1200`. The UTC instant is right; only the
applied offset is negated. (The same fault flips every zone: a US Eastern host
would report `+0500` instead of `-0500`.)

For contrast, MicroHttp's libc FFI path (`localtime`/`strftime`) returns the
correct `2026-06-15T07:47:47.172+1200` for the same instant.

## Path From User Function To The Fault

Traced in the installed `time-1.15` sources:

- `getCurrentTimeZone` / `getTimeZone` call `getTimeZoneCTime`
  (`lib/Data/Time/LocalTime/Internal/Foreign.hs:53-64`), which calls the C
  helper `get_current_timezone_seconds`, then builds
  `TimeZone (div (fromIntegral secs) 60) (dst == 1) name`. `TimeZone`'s
  convention is minutes **east** of UTC, positive meaning later than UTC
  (`lib/Data/Time/LocalTime/Internal/TimeZone.hs:23`).
- `get_current_timezone_seconds` is in C
  (`lib/cbits/HsTime.c:4-51`). It has two return paths:
  - `#if HAVE_TM_ZONE` (lines 27-29): `*pname = ptm->tm_zone;` and
    `return ptm->tm_gmtoff;` -- correct. `tm_gmtoff` is the signed east offset
    (`+43200` for NZ) and already accounts for DST.
  - `#else` fallback (lines 37-47): `*pname = *tzname;` (name correct) then
    `return dst ? timezone - 3600 : timezone;`. The C global `timezone` is
    seconds **west** of UTC, so for NZ it is `-43200`; returned un-negated, that
    is `-720` minutes, rendered `-1200`. This branch is sign-flipped relative to
    `TimeZone`'s east-positive convention for every zone.

## Root Cause

The macro gate in `lib/include/HsTime.h:4`:

```c
#if defined(_MSC_VER) || defined(__MINGW32__) || defined(_WIN32) || defined(__MHS__)
#define HAVE_TIME_H 1
#else
#include "HsTimeConfig.h"
...
#endif
```

For `__MHS__` it defines `HAVE_TIME_H` and **skips `HsTimeConfig.h`** -- the
autoconf-generated header that, on a normal Unix build, emits
`#define HAVE_TM_ZONE 1`, `HAVE_LOCALTIME_R 1`, `HAVE_TZNAME 1`, and
`HAVE_DECL_ALTZONE` (see `configure:3606,3757,3804,3834`). Under MicroHs those
macros are therefore all undefined, **even on macOS, whose `struct tm` does have
`tm_gmtoff`/`tm_zone`**.

With `HAVE_TM_ZONE` undefined, the correct `tm_gmtoff` path in `HsTime.c` is
compiled out and the code falls into the `#else` fallback. The fallback's name
assignment compiles under MicroHs only because of the `|| defined(__MHS__)`
added at `HsTime.c:38`, which routes it to `*tzname` (giving the correct name)
while the return value comes from the `timezone` global with the wrong sign.

In short: the MicroHs port disables the accurate `tm_gmtoff` branch by not
defining `HAVE_TM_ZONE`, leaving a fallback that returns the offset negated. The
correct name plus the negated offset is exactly the observed symptom.

## Why It Only Bites Under MicroHs

On a stock GHC/Unix build, `configure` defines `HAVE_TM_ZONE` (and
`HAVE_LOCALTIME_R`), so the `tm_gmtoff` path is taken and the result is correct.
The fallback is intended for platforms lacking `tm_gmtoff`; routing a
`tm_gmtoff`-capable platform (macOS) into it via the skipped config is what
exposes the fallback's sign error.

## Two Possible Fixes (either suffices)

- Have the MicroHs `time` build define `HAVE_TM_ZONE` (and `HAVE_LOCALTIME_R`)
  on Unix targets -- i.e. do not skip `HsTimeConfig.h` for `__MHS__` on Unix, or
  ship an mhs-specific config that sets them. This uses `tm_gmtoff`, which is
  correct and DST-aware.
- Correct the fallback's sign in `HsTime.c` to
  `return -(dst ? timezone - 3600 : timezone);`, since `timezone` is seconds
  west of UTC and `TimeZone` wants east-positive.

The first is preferable: `tm_gmtoff` is the accurate source and avoids relying
on the `timezone`/`tzname` globals at all.

## Local Mitigation Applied

MicroHttp does not use `Data.Time` for the access-log timestamp. `localTimestamp`
in `src/MicroHttp/Log.hs` calls libc `localtime` then `strftime` directly via
FFI, handing the opaque `struct tm` pointer straight from one to the other. That
path is the system's own local-time conversion, so it is correct on this
toolchain. A code comment at the FFI records this rationale so the function is
not "simplified" back to `Data.Time` while the fault stands. See also ADR-029 in
`docs/decision-register.md`.
