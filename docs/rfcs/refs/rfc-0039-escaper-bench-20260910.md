# RFC-0039 HTML Escaper Benchmark (2026-09-10)

Supporting evidence for [RFC-0039](../rfc-0039-constant-space-document-handling.md), rollout step 2.
Records why the byte-level escaper is written in C rather than as a pure Haskell `memchr` scan, which
the RFC had proposed with the C escaper held in reserve. Measured with `make bench-html-builder`
(`test/bench/HtmlBuilderBench.hs`, "document escape" section) and a scratch probe, on the same machine
as the memory profile.

## Escaper Fixtures

Two 260KB documents, escaped through the live path the editor page uses to embed a document body.

| Fixture      | Specials per byte | Escaped bytes | Note                                                  |
| ------------ | ----------------- | ------------- | ----------------------------------------------------- |
| `prose-260k` | 1 in ~50          | 279,001       | prose-like: quotes, ampersands, a comparison per line |
| `dense-260k` | 1 in ~2           | 754,001       | code-like: every few bytes is a special               |

For calibration, the real corpus (`cello-docs`, 82 documents over 20KB) has at most one special per
16 bytes; its densest document is the 263KB one with 16,330 specials. So `dense-260k` is roughly seven
times denser than anything served, and the realistic worst case sits between the two fixtures.

## Escaper Timings

Microseconds per document, CPU time, 20 documents per row.

| Escaper                                 | `prose-260k` | `dense-260k` |
| --------------------------------------- | ------------ | ------------ |
| `String` round-trip (before)            | 85,591       | 153,183      |
| Haskell `memchr` scan, five cached hits | 35,646       | 570,729      |
| C escaper (after)                       | 1,253        | 12,403       |

The `memchr` scan kept the next position of each of the five specials and refreshed only the one it
consumed, so it made one foreign call per special. Splitting its cost with a probe on a one-special-per-16-
bytes fixture (16,000 specials, ten runs): the scan alone took 33ms, building the piece list 71ms, and the
pairwise concat brought it to 81ms against 89ms for the `String` round-trip. Each `memchr` call costs 2 to
3 microseconds under mhs, so any per-special foreign call is bounded below by that, and on the dense
fixture it was three times slower than the code it replaced. Rewriting the loop with the five positions as
plain arguments instead of a list of pairs made it slower still (47ms and 861ms), so the cost is the
foreign call, not the bookkeeping.

The C escaper makes two foreign calls per document (length, then escape) and copies the bytes twice
(the escape itself and the pack into a `ByteString`). Its memory is the input plus the output, in C
buffers outside the mhs cell heap; nothing is unpacked to a list.

## Escaper Decision

Take the C escaper. It is 68 times faster than the `String` round-trip on prose and 12 times faster on
the dense fixture, and it removes the per-request heap spike the memory profile attributed to the
escaper. Because it writes to a buffer it is an `IO` function, per ADR-0086's rule that `unsafePerformIO`
covers only read-only scans; the three handlers that build the editor page already run in `IO` and
escape the body before handing it to the view as an opaque `Html.Escaped` value.
