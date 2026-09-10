---
id: ADR-0086
name: Pure FFI byte scanning via unsafePerformIO over a private copy
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-10
updated: 2026-09-10
supersedes: []
superseded_by: null
related_rfcs: [RFC-0029, RFC-0039]
---

# ADR-0086: Pure FFI byte scanning via unsafePerformIO over a private copy

## Context

MicroHs's `Data.ByteString` implements its scanning functions by unpacking to a list and walking it in the
interpreter: `elemIndex c = P.elemIndex c . unpack`, `findIndex k = P.findIndex k . unpack`,
`find p = P.find p . unpack`. Every scan therefore materialises the whole ByteString as a cons-list, O(n)
cells per call and interpreted per byte. A pure-Haskell scanner measured 4.5x slower and 5.6x more cells than
the alternative (RFC-0029's link-parse work), so the byte-scanning hot paths -- `Verso.DocumentLinks.pageLinks`
and `Verso.SearchChunks.lineRanges` -- call libc `memchr` through the FFI instead.

An FFI call is `IO`, but these scanners are pure functions used from pure code (`LinkIndex.updatePage`,
`DocumentListing`). `unsafePerformIO` reconciles the two. Three uses of `unsafePerformIO` existed in
production with no recorded decision: the two scanners, and a top-level global `IORef` in `MicroHttp.Log`
(`consoleQuiet`). This ADR records which of those is sanctioned and which is not.

## Decision

`unsafePerformIO` is permitted for exactly one shape: wrapping a **deterministic, side-effect-free foreign
call over a private marshalled copy of the argument**, where the result is a function of the argument's
bytes alone. Concretely, a sanctioned use:

1. marshals the ByteString into a private buffer with `useAsCStringLen` (a copy the callee cannot alias);
2. calls only read-only C over that buffer (`memchr` and the like), never anything that writes, allocates
   observably, or touches shared state;
3. returns a value determined solely by the bytes passed in;
4. documents these invariants at the call site.

`unsafePerformIO` is **not** permitted for global mutable state. The top-level `IORef` idiom
(`consoleQuiet = unsafePerformIO (newIORef False)`) is retired; the console sink is injected instead, the way
the access `Logger` already is.

## Why

Wrapping a pure foreign function is the canonical, textbook use of `unsafePerformIO`: under the four
invariants the expression is referentially transparent, so purity is preserved in fact, not just in type.
The performance case is measured, not assumed (RFC-0029: link parsing 85MB -> 15MB, 35ms -> 8ms per 73KB
page). The alternatives fork the design: a pure-Haskell scanner reintroduces the interpreted per-byte cost,
and making the scanners `IO` either turns their pure callers into `IO` or forces a second, separate scanner
for small inputs -- two implementations that must be kept byte-identical, which is the failure mode a single
shared core exists to prevent (RFC-0039).

The global `IORef` is a different animal. It is not a pure computation dressed as one; it is hidden mutable
state that any code can flip, invisible to types and to tests. The framework already models the same need
correctly for access logging by injecting a `Logger`, so there is no reason to keep the exception.

## Reopens when

- MicroHs gains a native, C-backed ByteString search (a runtime `memchr`-style `elemIndex`), making the FFI
  detour unnecessary.
- A use arises that needs anything beyond read-only scanning of a private copy -- that is a sign the
  computation is not pure and must be `IO`, not a new exception.

## Consequences

Each sanctioned site must satisfy all four invariants and state them in its comment; RFC-0039's shared
`scanStep` core is the intended home for byte scanning, so new scanners extend it rather than adding fresh
`unsafePerformIO` sites. A grep gate over `unsafePerformIO` with an allowlist of the sanctioned modules is
cheap and keeps the set from growing silently. The `consoleQuiet` global is replaced by an injected console
sink in a separate, behaviour-preserving change (18 call sites across `Verso.App` and `Verso.Main`; the
test binaries pass a silent sink instead of calling `silenceConsoleLog`).
