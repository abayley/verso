---
id: ADR-0038
name: HTML Rendering As A Coalesced ByteString Builder
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0038: HTML Rendering As A Coalesced ByteString Builder

## Context

`MicroHttp.Html` was a writer monad over `String`
(`newtype Html a = Html (String, a)`, `>>=` doing `left ++ right`), and the
TestApp rendered it then copied the whole page with `BS.pack` into a strict
body -- repeated `[Char]` appends plus a whole-page copy. A measurement spike
(`bench/HtmlBuilderBench.hs`, `make bench-html-builder`) on mhs 0.16.3.0
compared representations and, crucially, measured the socket cost: a difference
list of `ByteString` renders 12-24% faster than the `String` writer, but
emitting one `sinkChunk` (one `sendAll`) per fragment costs ~70x the syscalls of
one buffer-sized write. The 0.16.3.0 toolchain also fixes the `ByteString`
corruption fault that made a ByteString-heavy renderer risky (ADR review item,
`docs/microhs-bytestring-bug-report.md`). The design is RFC-0013.

## Decision

Render HTML through a difference-list builder of `ByteString`
(`newtype Builder = Builder ([ByteString] -> [ByteString])`, O(1) append by
composition); `Html` keeps its writer shape with the accumulator swapped from
`String` to `Builder`, and the combinator API is unchanged. Constant tag and
escape fragments are pre-packed CAFs; only dynamic, escaped text packs per
render, coalescing runs of safe characters into one chunk. `renderHtml ::
Html a -> String` is retained (byte-identical to the old renderer, pinned by the
`HtmlSpec` golden cases) for tests and `String` callers; `renderChunks ::
Html a -> [ByteString]` coalesces the builder output into >=16 KB segments
before the socket -- one segment for a typical page -- so the write count stays
as low as the old single `sendAll`. The TestApp builds HTML responses from
`renderChunks` concatenated into one `StrictBody`. A `ChunksBody [ByteString]`
that streams a large page's segments without a page-sized allocation is
specified but deferred: no current page approaches the buffer (the editor shell
is ~1.2 KB).

## Consequences

HTML responses drop the `[Char]` appends and the whole-page
pack-copy for a 12-24% CPU win, with no change to the rendered bytes or the
socket write count, and no new dependency (no `Data.ByteString.Builder` under
mhs). Coalescing is the contract, not raw per-fragment streaming, which the
spike showed is a ~70x socket-write pessimisation -- the lesson mirrors
blaze-html's buffer-filling builder. `renderHtml`'s `String` is now derived from
the chunks (`concatMap BS.unpack`), so it round-trips through Char8, matching the
wire bytes the `BS.pack` step already produced.
