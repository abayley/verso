---
id: ADR-0089
name: HTML responses are streamed, not materialised
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-12
updated: 2026-09-12
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0013, RFC-0020, RFC-0040]
---

# ADR-0089: HTML responses are streamed, not materialised

## Context

A document page is not rendered Markdown: it is the editor shell around a `<textarea name="markdown">` that
holds the document's raw Markdown, HTML-escaped, for the client to render (RFC-0020). So a page is a ~14KB
shell plus the document's bytes with `<`, `>`, `&`, `"` and `'` expanded to entities. RFC-0013 built that
page whole on purpose: `renderChunks` coalesced with a strict `foldl`, `escapeBytes` produced the escaped
document as one value, and the segments were concatenated into one more page-sized buffer, so the
`Content-Length` was exact. Its non-goal read "no streaming of partially-rendered pages to the socket before
rendering finishes", and it deferred even the segment-wise `ChunksBody` because "no current page approaches
16 KB" -- true in June, and no longer true once RFC-0020 embedded the document in the page. The largest
corpus document is a 356KB response held whole per request, and RFC-0040 made every other request and
response path constant-space, leaving this the last whole-body copy on the read path.

## Decision

An HTML document page is streamed in memory bounded by a block and a segment, whatever the document's size.
`Http.ResponseBody` carries a `SizedStreamBody Int Enumerator`: a length known before the first byte and an
enumerator that produces the body a segment at a time. `writeResponse` writes the head with that exact
`Content-Length` (`serialiseSizedHead`) and drives the enumerator through `sinkChunk`; the request logger
counts it as it does a close-delimited `StreamBody`. `Html.coalesce` yields a 16KB segment as soon as it
fills rather than folding the whole chunk list first, so the builder's lazy fragment list flows through with
one segment in hand. `View.editorPage` is a template with one hole: `View.editorShell` gives the shell
before and after the textarea's content as two `Html` values, and the handler streams the document between
them. The document's escaped length is counted first, over the file in 64KB blocks
(`Stream.foldFileBlocks` with `Html.escapedLength`), and the document is then read again in 64KB blocks and
escaped per block (`Stream.transformedFileBody` with `Html.escapeBlockBytes`); the escaper works byte by
byte, so a block boundary can never split an expansion and block-wise escaping equals whole escaping. The
exact `Content-Length` is kept: it is `length(before) + escapedLength + length(after)`, and two reads from
the page cache is the price. A page whose content is already in memory -- a staged draft, a new page's seed,
or a revision captured from git (RFC-0032) -- is escaped once and emitted through the same `SizedStreamBody`,
so the response contract is uniform.

## Why

- Byte-identical to the whole page it replaced, proven end to end: for the 263KB corpus document, the
  streamed read view is 356,394 bytes and the streamed edit view is 356,575 bytes, each identical byte for
  byte to the pre-change build's output for the same request, with a `Content-Length` header matching the
  received body exactly. The shell split is checked directly in `Verso.ViewSpec` (`editorPage` equals its
  `editorShell` split around the content, edit and read views, at ~260KB with every escaped byte), and
  block-wise escaping is checked against whole escaping at every block size in `MicroHttp.StreamSpec`.
- Memory per response is the shell plus one 64KB block plus one 16KB segment, independent of document size,
  because the document is never held whole. Measured on the real corpus at the 8,000,000-cell default,
  resident memory plateaus at ~151MB across 100 sequential reads of the largest document with no
  per-request growth, and the warm read latency is ~32ms.
- The exact length is what a well-behaved producer owes proxies and clients; counting first keeps that
  rather than falling back to the close-delimited framing `StreamBody` uses, and keeps the response contract
  uniform across pages.

## Reopens when

Keep-alive arrives (a later RFC): a keep-alive connection needs the length for framing regardless, so the
sized stream stays, but `Connection: close` on these responses is revisited then. Streaming rendered
(server-side) Markdown, rather than the raw document in a textarea, would change what is counted and escaped
and would reopen the counting pass.

## Consequences

- Every document response now takes the `SizedStreamBody` shape; a handler that builds a page around a
  document hole uses `View.editorShell` and one of the document response builders in `Verso.App`, not
  `View.editorPage` into a `StrictBody`.
- The page is read twice: once to count the escaped length, once to stream it. Both reads are from the page
  cache and neither holds the file.
- `Html.coalesce` is lazy; a caller that relied on it forcing its whole input no longer gets that (there is
  no such caller). The strict `ChunksBody` deferred by RFC-0013 is superseded by the sized stream.
- `treeReadAt` still holds the git capture in memory until RFC-0040 phase 5 leaves that capture on disk; it
  emits it through the same `SizedStreamBody` in the meantime.
