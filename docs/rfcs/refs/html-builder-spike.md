# HTML Builder Representation Spike

A measurement spike for RFC-0013: which HTML builder representation is worth
adopting under MicroHs, settled with numbers rather than guesswork. The open
ADR review item -- "confirm whether MicroHs `ByteString` performance is
acceptable" -- is the reason this is measured.

Code: `bench/HtmlBuilderBench.hs`, run with `make bench-html-builder`. It renders
a representative page (200 elements, each a constant tag pair around dynamic,
HTML-escaped text; ~14 KB, ~600 fragments) many times through each candidate
strategy and reports CPU time via `System.CPUTime`, then sends a rendered page
over a connected loopback socket pair to measure the real cost of the chunking
choice. All strategies are checked to emit byte-identical output (14153 B/page).

## Toolchain

Re-run on MicroHs 0.16.3.0 (combinator file v8.4), which fixes the `ByteString`
corruption fault (`docs/microhs-bytestring-bug-report.md`); the reproducer now
packs large lazily-built `ByteString`s correctly after a `forkIO`. The numbers
below are from 0.16.3.0. On this runtime the absolute render times are a little
higher than the earlier patched-0.16.0.0 measurements and the relative spread is
narrower, but the ordering is unchanged.

## What was measured

- **current** -- the live path: the `MicroHttp.Html` `String` writer, then
  `BS.pack` of the whole page.
- **bs-naive** -- left-nested `BS.append` of every fragment into one strict
  `ByteString`.
- **dlist-concat** -- a difference list (`[ByteString] -> [ByteString]`, O(1)
  append by composition), flattened then `BS.concat`.
- **dlist-stream** -- the same difference list, summed per chunk (modelling a
  per-fragment `sinkChunk` write, no concatenation).
- **dlist-coalesce** -- the difference list packed into 16 KB segments (a
  blaze-style buffer), then summed per segment.
- **rope-concat / rope-stream** -- a chunk tree (O(1) append by node),
  flattened then concatenated, or summed per chunk.
- **constant fragment cost** -- packing a short literal on every use versus a
  pre-packed CAF.
- **socket write cost** -- sending one rendered page over a connected loopback
  pair as per-fragment chunks, as 16 KB coalesced segments, or as one buffer,
  3000 pages, reporting sends/page and time/page.

## Findings: rendering CPU

CPU ns per page, mhs 0.16.3.0, stable across runs:

| Strategy       | ns/page (approx) | vs current |
|----------------|------------------|------------|
| current        | 3,300,000        | baseline   |
| bs-naive       | 2,790,000        | ~15% faster|
| dlist-concat   | 2,760,000        | ~16% faster|
| dlist-stream   | 2,520,000        | ~24% faster|
| dlist-coalesce | 2,890,000        | ~12% faster|
| rope-concat    | 2,810,000        | ~15% faster|
| rope-stream    | 2,700,000        | ~18% faster|

- Moving off the `String` writer is the main CPU win: every `ByteString`
  strategy beats `current` by 12-24%, dropping both the `[Char]` appends and the
  whole-page pack-copy.
- A difference list is the best representation, narrowly ahead of a rope, and
  needs no node type -- just composition.
- Coalescing adds a little CPU over raw `dlist` (it does the `BS.concat` work)
  but stays ahead of `current`.
- Constant-fragment packing is cheap (pack-each ~189 ns, shared-caf ~238 ns):
  packing a short tag under mhs is not a cost worth engineering around. Sharing
  tags as CAFs is for clarity, not speed.

## Findings: socket write cost (the decisive result)

A 200-element page is ~600 fragments. Each `sinkChunk` is one `sendAll` -- one
`send()` -- on the socket sink. Sending the page over a loopback pair:

| Strategy  | sends/page | us/page |
|-----------|------------|---------|
| per-chunk | 600        | ~973    |
| coalesced | 1          | ~14     |
| one-shot  | 1          | ~11     |

- **Per-fragment streaming is a ~70x socket-write pessimisation.** Sending 600
  tiny chunks costs ~973 us/page in syscall overhead; one buffer-sized write
  costs ~11-14 us. That ~1 ms would swamp the ~0.8 ms of rendering CPU saved by
  moving to a builder -- a net loss.
- **Coalescing recovers it.** Packing the difference list into 16 KB segments
  collapses a 14 KB page to a single send (coalesced == one-shot for pages under
  the buffer), at one O(n) pass. This is exactly what blaze-html's buffer-filling
  builder does, and why blaze does not emit a chunk per fragment.
- The current `StrictBody` path already sends one `sendAll`; a naive
  per-fragment `ChunksBody` would regress that to ~600 sends. Coalescing keeps
  the single write while still building in O(1).

## Recommendation

- **Representation:** a difference list of `ByteString`
  (`newtype Builder = Builder ([ByteString] -> [ByteString])`), O(1) append by
  composition. No new dependency, no node allocation, works on mhs.
- **To the socket:** do **not** stream per fragment. Coalesce the builder output
  into buffer-sized (~16 KB) segments and `sinkChunk` those -- for a typical
  page that is a single write, matching today's `StrictBody` send count while
  dropping the `[Char]` appends and the double copy. Per-fragment `dlist-stream`,
  despite the best CPU number, is rejected on the 70x socket penalty.
- **Body shape:** for pages below the buffer (the editor's pages are ~14 KB), a
  single coalesced `ByteString` is effectively `StrictBody`; a `ChunksBody` of
  coalesced segments earns its keep only for pages larger than the buffer, where
  it avoids one page-sized allocation and streams in bounded segments. The RFC
  should make coalescing the contract, not raw per-fragment chunks.
- **`Content-Length`:** sum the segment lengths in one in-memory pass for an
  exact length.
- **Constant tags:** share as pre-packed CAFs for tidiness, not for speed.

## Status

Spike complete and re-run on the fixed 0.16.3.0 toolchain. It resolves
RFC-0013's representation and body-path Open Questions, and corrects the earlier
CPU-only conclusion (which favoured per-fragment streaming) with the socket
measurement. The bench (`bench/HtmlBuilderBench.hs`) stays as a measurement
tool; re-run with `make bench-html-builder` if the toolchain or `ByteString`
implementation changes.
