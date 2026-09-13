---
id: ADR-0091
name: Network and file I/O is block-streaming by default
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-13
updated: 2026-09-13
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0013, RFC-0014, RFC-0039, RFC-0040]
---

# ADR-0091: Network and file I/O is block-streaming by default

## Context

RFC-0040 worked through every request, response, file, and subprocess path that held a whole payload in the
heap and made each one constant-space. Along the way the framework grew a set of streaming primitives, but
the decision behind them was implicit: each path was fixed on its own, and a new handler could still reach
for `BS.readFile`, `BS.writeFile`, a whole-body `readBodyStrict`, or a whole-subprocess capture without
anything saying it was the wrong default. Under MicroHs that default is a trap twice over: a whole payload is
a `malloc`'d `ByteString` outside the cell arena, so it never triggers a collection and a burst of them can
exhaust the host without `heap exhausted` ever firing (the upload DoS, ADR-0088); and unpacking one to a
`String` costs ~24 bytes a byte. The primitives also arrived piecemeal -- two different hand-rolled "open,
read in blocks, close" loops existed at once -- so "how you stream a file" had no single answer.

## Decision

Network and file I/O is **block-streaming by default**. A handler, or any new code under `packages/*/src`,
processes a request body, a response body, a file, or a subprocess capture as a bounded sequence of blocks
(or lines), never as a whole in-heap value, unless the payload is provably bounded and small -- in which
case the whole-value read is allowed with the bound recorded at the call site or in the owning RFC.

The framework provides the vocabulary, and there is one bracket underneath the read side:

- **One read bracket.** `Iteratee.resourceEnumerator` owns open/read/close on every exit path;
  `Stream.fileEnumeratorChunked` is the file block producer over it. `Stream.foldFileBlocks` (fold a file's
  blocks) and `Stream.foldFileLines` (fold its lines, carrying the partial line across block boundaries) are
  built on that producer, so there is a single place that opens a file for reading.
- **Reading to a value only when bounded.** `Iteratee.readBodyStrict` stays for bodies that must be values,
  behind a small cap. Whole-file `BS.readFile` is for bounded-small metadata (a manifest, a sidecar, a
  folder index), each with a recorded bound.
- **Transforming and comparing without materialising.** `Stream.transformedFileBody` /
  `transformedTempFileBody` (stream a file through a per-block transform into a response, optionally deleting
  it after), `Stream.fileContains` (streamed substring), `Stream.filesEqual` (streamed comparison),
  `Stream.fileSinkI` (stream a body to a file), `Stream.writeFileLines` (stream lines out).
- **Responses.** `Http.FileBody` (zero-copy `sendfile`), `Http.SizedStreamBody` (a streamed body with an
  exact `Content-Length` counted first, ADR-0089), and `Http.StreamBody` (close-delimited, when the length
  cannot be counted cheaply -- the streamed diff).
- **Subprocess output.** `Process.runProcessCaptured` leaves stdout/stderr in capture files the caller
  streams or renames (ADR-0090); `runProcess` (read to a value) is for small commands.

## Why

- It removes the memory-exhaustion class structurally rather than per-handler: a body, page, file, or capture
  that is streamed cannot pull its whole size into the arena, so the default is safe on a fixed,
  non-growable heap (ADR-0088, RFC-0040 security impact).
- It is measured, not assumed. RFC-0040 measured each path before and after: uploads dropped from ~56x the
  body to a bounded buffer; the largest document render went from a whole-page copy to a shell plus one block
  plus one segment; the link-index persist stopped building a ~1.2MB `String`. The one path where the peak is
  not the framework's -- search indexing, dominated by the ONNX runtime and lancedb -- is recorded as such.
- One read bracket means the open/read/close discipline (close on early stop, on failure, on completion) is
  written once and inherited, rather than re-derived per reader and drifting.

## Reopens when

A payload is provably bounded and small: a whole-value read is fine, with the bound recorded. The bounded
exceptions today are the small metadata parsers (`Trash`, `DocumentMeta`, `DocumentListing` over index.md)
and `Html.escapeChars`'s `String` path for static UI text; see RFC-0040's "Deferred and recorded items". This
ADR does not compel rewriting those, only that a new unbounded path streams.

A second multi-source consumer appears. The push enumerator drives one consumer with a single input channel,
which fits produce -> transform -> consume pipelines and sequential fan-in (feed one sink from several
sources in turn, as the streamed diff does via `Iteratee.feedChunk`). It does not fit a lock-step *combination*
of two sources -- the two-file compare `Stream.filesEqual` reads both handles in step and is hand-rolled for
that reason (not via the readers). The principled way to express lock-step or k-way source combination stays
inside the iteratee paradigm rather than adding a second one: generalise `Iteratee.Iter e a` from its fixed
`IO` base to a base-monad-parametric transformer (`IterT e m a`, `IterM (m ...)`), so a consumer can nest a
second iteratee as its base monad and read both streams under its own control (Oleg Kiselyov's iteratee
"several sources to one sink", the 2enum1iter construction). That touches the core's monad plumbing
everywhere, so it is deferred until a second lock-step or merge consumer (merging sorted index shards is the
plausible one) justifies it; at that point `filesEqual` moves onto nested iteratees and the hand-rolled loop
retires. The design, the discussion, and a working spike are written up in RFC-0041.

## Consequences

- New handlers reach for the streaming vocabulary above; a whole-value read of an unbounded input is a
  defect, caught in review against this ADR.
- Streaming shifts some costs: a sized response reads its source twice (count, then stream); a streamed
  response that fails mid-body has already sent its status line (true of every streamed body, RFC-0040
  reliability impact); a close-delimited body carries no `Content-Length`.
- The two-file-lockstep comparison (`Stream.filesEqual`) and the write side (`fileSinkI`, `writeFileLines`)
  do not fit the single read enumerator and are their own brackets; that is expected for now, with the
  principled unification (a base-monad-parametric iteratee) recorded under "Reopens when".
