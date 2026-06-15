---
id: RFC-0013
name: HTML Response Builder
status: Completed
owners:
    - alistair
created: 2026-06-13
updated: 2026-06-15
supersedes: []
superseded_by: null
---

# HTML Response Builder

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-06-13 |
| Started   | 2026-06-15 |
| Completed | 2026-06-15 |

## Summary

Replace the `String`-append-then-`pack` HTML rendering with a builder that
accumulates a difference list of `ByteString` chunks (O(1) append by
composition), coalesces them into buffer-sized segments, and writes those few
segments to the socket through the existing `ResponseSink.sinkChunk`, with an
exact `Content-Length` from summing the segment lengths. This drops both the
repeated `[Char]` appends and the whole-page `pack`-copy while keeping the
socket write count low. It is a performance change only: the rendered bytes are
identical and the RFC-0012 response contract is unaffected. The representation
*and the coalescing* were chosen by measurement
(`docs/design/html-builder-spike.md`, `make bench-html-builder`) on MicroHs
0.16.3.0; the spike also confirms the `ByteString` corruption fault is fixed in
0.16.3.0, closing the open ADR review item on MicroHs `ByteString` behaviour.

## Context

The current `MicroHttp.Html` is a writer monad over `String`
(`newtype Html a = Html (String, a)`, with `>>=` doing `left ++ right`), and
`TestApp` renders it and then copies the whole thing with `BS.pack` into a
single strict body (`StrictBody (BS.pack body)`). That is two layers of waste:
repeated `String` (`[Char]`) appends, then a whole-page copy.

A measurement spike (`bench/HtmlBuilderBench.hs`) rendered a representative
~14 KB page (~600 fragments) through several strategies, all emitting
byte-identical output, then sent a rendered page over a connected loopback pair.
The results (mhs 0.16.3.0, stable across runs):

- Every `ByteString` strategy beats the current `String` path by 12-24% of CPU,
  dropping both the `[Char]` appends and the whole-page pack-copy. A difference
  list is the fastest representation, narrowly ahead of a chunk tree (rope), and
  needs no node type -- just composition.
- The decisive result is the socket cost. Each `sinkChunk` is one `sendAll`
  (one `send()`); sending the page as ~600 per-fragment chunks costs ~973 us,
  versus ~11-14 us as a single buffer-sized write -- a ~70x penalty. That ~1 ms
  would swamp the ~0.8 ms of rendering CPU the builder saves. So the chunks must
  be coalesced into buffer-sized segments before the socket; per-fragment
  streaming is rejected.
- Packing a short constant tag under mhs is cheap; sharing tag fragments as CAFs
  is for clarity, not speed.
- MicroHs 0.16.3.0 fixes the `ByteString` corruption fault
  (`docs/microhs-bytestring-bug-report.md`); the full suite is green on it.

The editor already streams file chunks through `ResponseSink.sinkChunk`
(RFC-0014); HTML reaches the socket the same way, so this also unifies the
in-memory and file body paths and lets a future RFC-0012 logging middleware
count response bytes through `egress` uniformly.

RFC-0012 leaves HTML rendering as-is on purpose, so this is done independently
and later.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Build HTML as a difference list of `ByteString` chunks with O(1) append,
  coalesced into a few buffer-sized segments for the socket rather than one
  whole-page buffer or hundreds of per-fragment writes.
- Keep the existing combinator API (`el`, `text`, attributes, the named
  elements, `IsString`) source-compatible, so `TestApp` and tests are
  unaffected except where they construct the response body.
- Fit the RFC-0012 response contract: the body becomes a chunk stream sunk
  through `sinkChunk`, with an exact `Content-Length` from summing chunk
  lengths.
- Preserve HTML escaping exactly: the rendered bytes byte-match the current
  renderer for every existing `HtmlSpec` case.

## Non-Goals

- No change to the request-handling contracts from RFC-0012, nor to the status
  line, header serialisation, or `Connection: close` behaviour.
- Not zero-allocation: escaping dynamic text inherently allocates; the goal is
  no whole-page concatenation or `pack`-copy of constant structure.
- No streaming of partially-rendered pages to the socket before rendering
  finishes: the chunk list is built in memory (so `Content-Length` is exact),
  then written. Lazy/incremental production is out of scope.
- No new HTML combinators or template features; the surface is unchanged.
- No keep-alive or chunked transfer-encoding; bodies stay `Connection: close`
  with an exact length (consistent with RFC-0014).

## Proposal

### The builder representation

`Html`'s output type changes from `String` to a difference list of
`ByteString`:

```haskell
newtype Builder = Builder ([ByteString] -> [ByteString])
```

`mempty` is `Builder id`; append is composition (`Builder f <> Builder g =
Builder (f . g)`), which is O(1). A single fragment is `Builder (chunk :)`.
Running a builder is `run (Builder f) = f []`, yielding `[ByteString]` in
document order.

`Html` keeps its writer shape with the accumulator swapped:

```haskell
newtype Html a = Html (Builder, a)
```

`>>=`, `<*>`, and `pure` thread the builder exactly as today, with `<>` in place
of `++`. `emit` takes a `ByteString` chunk. Constant tag fragments
(`"<div"`, `">"`, `"</div>"`, the escape replacements) are pre-packed top-level
CAFs; only dynamic escaped text allocates per render. Escaping maps each special
character to a shared replacement chunk (`BS.concatMap` over the packed text).

The combinator API (`el`, `voidEl`, `text`, `rawTrusted`, attributes, the named
elements, the `IsString (Html ())` instance) keeps its current signatures, so no
caller changes. `renderHtml :: Html a -> String` is retained (it concatenates
the chunks back to a `String`) so the `HtmlSpec` golden tests are unchanged; a
new `renderChunks :: Html a -> [ByteString]` produces the body chunks.

### Coalescing before the socket

`renderChunks` does not hand the raw ~600 fragments to the socket. The builder
output is coalesced in one O(n) pass into segments of at least a buffer size
(~16 KB), so a typical page becomes a single segment and a large page becomes a
handful. This is the blaze-html buffer-filling builder's job, done explicitly:
the spike showed per-fragment writes cost ~70x the syscalls of one buffer-sized
write, which would swamp the rendering win. `renderChunks :: Html a ->
[ByteString]` returns the coalesced segments.

### The response body

For pages below the buffer (the editor's pages are ~14 KB) the coalesced result
is a single `ByteString`, so the body stays `StrictBody (one segment)` -- the
same single `sendAll` as today, with the `[Char]` appends and double copy gone.
That is the whole win for the common case and needs no new constructor.

A new `ResponseBody` constructor is justified only to stream a *large* page as
its few buffer-sized segments without one page-sized allocation:

```haskell
| ChunksBody [ByteString]   -- already coalesced to buffer-sized segments
```

`writeResponse` handles it by computing the exact length once
(`sum (map BS.length segments)`), writing a head with that `Content-Length`
(the same shape as `serialiseFileHead`), then sinking each segment in order
through `sinkChunk`. `serialiseResponse` (the pure path used by tests that
compare whole responses) flattens a `ChunksBody` with one final `BS.concat`.
Whether to ship `ChunksBody` now or defer it until a page exceeds the buffer is
a phase-three decision (see Rollout); the small-page `StrictBody` path is the
required part.

`TestApp`'s `htmlResponse` switches from `StrictBody (BS.pack (renderHtml h))`
to building from `renderChunks h` (a single `StrictBody` when coalescing yields
one segment).

### Content-Length

Summed from the segment lengths in one in-memory pass (the segments are already
realised, so no copy) to send an exact length -- the in-memory counterpart to
RFC-0014's file-size approach. This keeps every HTML response exact-length and
eligible for a future keep-alive RFC.

## Alternatives Considered

- **Stream every fragment to the socket via `sinkChunk` (no coalescing).** This
  had the best *CPU* number in the first spike, so the earlier draft of this RFC
  chose it. The socket measurement overturned that: ~600 `sendAll` calls per
  page cost ~973 us versus ~11-14 us for one buffer-sized write -- a ~70x
  penalty that swamps the rendering saving. Rejected; coalescing is required.
- **Flatten the whole page to one `ByteString` (`StrictBody`) always.** For
  pages below the buffer this *is* the chosen path (coalescing yields one
  segment), and it is the simplest. The only thing it gives up is streaming a
  very large page in bounded segments without a page-sized allocation, which is
  what the optional `ChunksBody` adds. Not rejected -- it is the common-case
  body.
- **A chunk tree (rope) instead of a difference list.** Equivalent O(1) append,
  but measured slightly slower and needs a node type and a flattening walk. The
  difference list is simpler and faster. Rejected.
- **Left-nested `ByteString` append (`bs-naive`).** The slowest `ByteString`
  strategy in the spike (repeated copying); a builder that appends in O(1) is
  the point. Rejected.
- **A `Builder` from a bytestring library.** MicroHs has no
  `Data.ByteString.Builder`; the difference list is the dependency-free
  equivalent and measured well. Rejected as unavailable.
- **Lazy/streamed rendering to the socket without buffering.** Would forgo the
  exact `Content-Length` (or force chunked encoding) for no measured benefit at
  these sizes. Rejected; see Non-Goals.

## Security Impact

- HTML escaping of dynamic text must be preserved exactly. The escape function
  moves from `String -> String` to `ByteString`-producing, mapping the same five
  characters (`< > & " '`) to the same replacements; the golden `HtmlSpec` cases
  pin that the output bytes are unchanged, so the change cannot open an escaping
  gap.
- `rawTrusted` keeps its current trust contract (no escaping); only its argument
  is packed rather than concatenated.

## Reliability Impact

- Performance change; the rendered bytes must be identical to the current
  renderer for the same input, pinned by the existing `HtmlSpec` golden output
  plus chunk-boundary cases.
- The exact `Content-Length` is computed from the same chunks that are written,
  so the length and the body cannot disagree.
- No new failure modes on the socket path: `sinkChunk` already carries the
  streaming error handling used by `StrictBody` and `StreamBody`.

## Compatibility Impact

- The combinator API is unchanged, so `TestApp`, `HtmlSpec`, and other callers
  compile unchanged except where a response body is constructed (`htmlResponse`).
- `ResponseBody` gains a `ChunksBody` constructor; any exhaustive `case` over
  `ResponseBody` (the response sink, its `Eq`/`Show`) must handle it. This is an
  internal type, not an external contract.
- The wire output (status line, headers, exact `Content-Length`,
  `Connection: close`, body bytes) is byte-identical to today for the same page.

## Testing and Quality Gates

- `make check` stays green.
- The rendered output byte-matches the current renderer for existing `HtmlSpec`
  cases (golden), via `renderHtml` retained as `String`.
- New tests: `renderChunks` concatenated equals `renderHtml`; coalescing a small
  page yields a single segment and a page over the buffer yields the expected
  bounded count; escaping is preserved across a fragment/segment boundary. If
  phase three ships, a `ChunksBody` response serialises (pure path)
  byte-identically to the equivalent `StrictBody` and the streamed path emits the
  head with the summed `Content-Length` then each segment.
- `make bench-html-builder` remains runnable as a regression check on the
  representation if the toolchain changes.

## Rollout Plan

1. Phase one: the builder and coalescing, behind the unchanged combinator API.
   - [x] Introduced the `Builder` difference list and swapped `Html`'s
         accumulator from `String` to `Builder`; pre-packed constant fragments
         and escape replacements as CAFs. Kept `renderHtml :: Html a -> String`;
         added `renderChunks :: Html a -> [ByteString]` that coalesces the
         builder output into buffer-sized segments. `HtmlSpec` golden cases pass
         unchanged, plus new chunk/coalesce tests.
2. Phase two: switch the caller to a single coalesced body.
   - [x] `TestApp` HTML responses build from `renderChunks h` concatenated into a
         single `StrictBody` (via `htmlResponseChunks`/`documentResponse`, the
         doctype folded into the builder). Integration `TestAppSpec` confirms the
         responses are byte-identical on the wire; verified the app still serves
         (index, editor shell ~1.2 KB, fragments). Socket write count unchanged.
         `make check` green (bar the pre-existing `TODO.md` line-length).
3. Phase three (optional): stream large pages as segments. Deferred.
   - [ ] Not needed yet: no current page approaches the 16 KB buffer (the editor
         shell is ~1.2 KB), so `renderChunks` yields one segment and the single
         `StrictBody` send suffices. Add `ChunksBody [ByteString]` only if a real
         page later exceeds the buffer.
4. Phase four: document and close.
   - [x] ADR-038 records the builder + coalescing decision; the spike is noted.
         This RFC is Completed. `make bench-html-builder` (the `current` vs
         `dlist-coalesce` rows) captures the before/after.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

Resolved by the spike (`docs/design/html-builder-spike.md`, mhs 0.16.3.0,
2026-06-15):

- **Representation:** a difference list of `ByteString`
  (`[ByteString] -> [ByteString]`), the fastest measured and dependency-free.
- **Body path:** coalesce the builder output into buffer-sized segments. For a
  typical page that is one segment -> `StrictBody`, one `sendAll` (as today). An
  optional `ChunksBody [ByteString]` streams a larger page's few segments. Raw
  per-fragment streaming is rejected (~70x socket-write penalty in the spike).
- **`Content-Length`:** summed from the segment lengths for an exact length.
- **`Html` monad shape:** kept as a writer, with the output type swapped from
  `String` to the builder; the combinator API is unchanged.
- **MicroHs `ByteString` correctness and performance:** the corruption fault is
  fixed in 0.16.3.0 (suite green); packing short constants is cheap and the
  builder is 12-24% faster CPU than the `String` path.

None outstanding.
