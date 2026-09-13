---
id: RFC-0042
name: Streaming form consumer
status: Implemented
owners:
    - Alistair Bayley
created: 2026-09-13
updated: 2026-09-13
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0036, RFC-0040]
related_refs: []
---

# RFC-0042: Streaming form consumer

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-09-13 20:40 NZST |
| Started   | 2026-09-13 21:00 NZST |
| Completed | 2026-09-13 22:10 NZST |

## Summary

A form `POST` is the one request shape the framework still reads whole. `Http.parseFormBody` takes the
complete body as a `ByteString` and returns decoded fields, so a form with a document-sized field costs a
document-sized buffer, and the byte decoder that feeds it has a known ceiling: producing a decoded value as
a list overflows the fixed MicroHs evaluator stack somewhere above 350KB. Every other document path is now
block-streamed (RFC-0040, ADR-0091). This RFC proposes a **form consumer**: an iteratee that parses a form
body as a sequence of parts, each surfaced as its name followed by a body stream, and hands each part's body
to a sink chosen by name. Small fields are collected in memory under a per-field cap and a total cap; a
designated field streams to wherever the application says, decoded on the way in bounded blocks. The same
part interface serves `application/x-www-form-urlencoded` now and `multipart/form-data` when a caller needs
it. In Verso, the no-JavaScript save form routes its `markdown` field to a file sink and collects the rest,
which closes the last whole-body read on a document path and lets `formBodyLimit` mean page size only.

## Context

### The whole-body form path

`Verso.App.treeSave` is the no-JavaScript fallback for saving a page (RFC-0001, RFC-0036): the browser posts
the editor's `<textarea>` as a urlencoded form. Its shape today is

```haskell
bodyBytes <- Iteratee.readBodyStrict tooLarge formBodyLimit
let markdown = normaliseNewlineBytes (captureBytes "markdown" (Http.parseFormBody bodyBytes))
```

Three whole-body values exist in turn: the raw body, the decoded `markdown` value, and its newline-normalised
copy. RFC-0040 phase 2 made them bytes rather than `String`s, which removed the 24x cons-cell spike and the
30-second decode the phase-1 baseline measured, and the phase-4 to phase-9 work then streamed every response
and every other request path, including the editor's own raw-body `PUT`s (which stream into a temp file and
rename it into place since the RFC-0040 review). The form `POST` is what is left, and it is left because the
parser needs the body in hand to do its job as written, not because the encoding requires it.

### The decoder's ceiling

`Http.decodeFormValueBytes` decodes one value as `BSC.pack (go 0)`, a lazily produced list packed at the
end. Its own comment records the limit: above roughly 350KB the evaluator stack (a fixed 250,000 slots in the
MicroHs runtime, `STACK_SIZE` in `eval.c`, independent of heap size) overflows. Decoding in bounded blocks
and rejoining them was tried during phase 2 and did not move the threshold, and the RFC recorded the
mechanism as "not yet understood". A decoder that writes each decoded block to its destination and keeps no
list at all avoids the question rather than answering it.

### How other frameworks shape this

The survey behind this RFC found one converged design, applied almost universally to `multipart/form-data`
and almost never to urlencoded:

- The body is parsed as a sequence of **parts**, and each part's identity (its name, and for multipart its
  filename and content type) arrives **before** its body.
- Each part's body is handed to a **consumer chosen from that identity**. Node's `busboy` emits `field`
  events with in-memory values and `file` events carrying a stream; Go's `multipart.Reader.NextPart` returns
  an `io.Reader` per part; Rust's `axum` yields `next_field()` as a stream; Django's upload handlers and
  Werkzeug's stream factory receive chunks per part; `wai-extra`'s `parseRequestBodyEx` applies a `BackEnd`
  sink to each file part.
- **Defaults bound memory**: small fields are kept as values under per-field and total caps, and file-like
  parts spill to disk above a threshold (Go's `maxMemory`, Django's `FILE_UPLOAD_MAX_MEMORY_SIZE`, Rack's
  `Tempfile`, `wai-extra`'s `tempFileBackEnd`).

Urlencoded bodies are treated as small everywhere (Express caps them at 100KB, Go at 10MB in memory, Django
at 2.5MB) because the convention is that a large field belongs in multipart. A streaming urlencoded parser
is nonetheless straightforward, and the name still precedes the value, so the same routed-sink design fits
it. This RFC applies the converged design to the encoding Verso actually uses, over the iteratee model the
framework already has (RFC-0012), and leaves the part interface ready for multipart.

## Goals

- A form body is consumed in constant memory: no whole-body `ByteString`, no whole-value decoded copy, and
  no list proportional to a value's length.
- A part's body can be routed, by its name, to any `Iter` sink: an in-memory collector, a file sink, or a
  transforming sink such as Verso's decode-and-normalise-to-file.
- Fields not routed elsewhere are collected as decoded values with a **per-field cap** and a **total
  collected cap**, so one field cannot consume the whole body budget and the count of fields is bounded.
- Decoding is byte-identical to `Http.parseFormBody` for every body the old parser accepted, including a
  `%` escape split across a chunk boundary, `+` as space, an encoded `=` inside a value, a field with no
  `=`, an empty field, an empty body, and multibyte UTF-8 split across a boundary.
- `treeSave` routes `markdown` to a file, decoded and newline-normalised on the way, and the page is renamed
  into place as the raw `PUT` does (atomic replacement, no partial page on a crash).
- The retired decoder ceiling is recorded as fixed, with a test above the old threshold.

## Non-Goals

- Multipart parsing is **not implemented** by this RFC. The part interface is designed so a multipart parser
  can produce the same parts, and that is the reopen condition, not this scope.
- Changing the editor's save transport. The editor `PUT`s raw bytes (RFC-0036) and already streams; the form
  is the no-JavaScript floor.
- Re-ordering or buffering to let a routing decision depend on a field that arrives later. A sink is chosen
  from the name alone; a form that needs control fields before its large field puts them first (browsers
  preserve DOM order), and that ordering is part of the form's contract.
- Configurability of the caps. They are constants beside the handlers, as `formBodyLimit` is today; RFC-0040's
  open question about cataloguing `formBodyLimit` is unchanged by this RFC except that the limit becomes
  purely a page-size policy.

## Proposal

### The part interface

A form body is a sequence of parts. The consumer surfaces each part as its decoded name and then streams the
part's **raw** (still percent-encoded) body to a sink chosen for that name:

```haskell
-- MicroHttp.Form (new)

-- | What to do with one part's body, chosen from its decoded name.
data PartSink e a
    = -- | Decode and collect the value in memory, under the per-field cap.
      CollectField
    | -- | Stream the raw, still-encoded bytes to this sink; the caller decodes.
      SinkPart (Iteratee.Iter e a)

-- | The caps a collected form observes.
data FormLimits = FormLimits
    { maxFieldBytes :: Int   -- decoded bytes per collected field
    , maxCollectedBytes :: Int  -- decoded bytes across all collected fields, names and values
    , maxFields :: Int
    }

-- | Consumes a urlencoded body: the collected fields, decoded, in arrival order,
-- and the results of every routed sink, paired with their field names.
formI ::
    FormLimits ->
    e ->
    (BS.ByteString -> PartSink e a) ->
    Iteratee.Iter e ([(BS.ByteString, BS.ByteString)], [(BS.ByteString, a)])
```

The routed sink receives the raw bytes so it can choose its own decoding and, in Verso's case, fuse the
newline normalisation into the same pass. The framework supplies the decoding stage as a reusable
transformer so a caller does not reimplement it:

```haskell
-- | Percent-decodes a stream of urlencoded value bytes (+ as space) block by block,
-- carrying a split escape across chunk boundaries, into the given sink.
decodeFormValueI :: Iteratee.Iter e a -> Iteratee.Iter e a
```

so `SinkPart (decodeFormValueI (Stream.fileSinkI cap tooLarge tmp))` is a decoded-to-file part, and
`CollectField` is `decodeFormValueI` into a bounded in-memory collector, which is how the framework
implements it.

### The urlencoded parser as an iteratee

The parser is a state machine over chunks with a small carry, in the style of `Stream.foldFileLines`'s line
carry and `Stream.fileContains`'s overlap:

- **In a name**: scan the chunk for `=` or `&` with `Bytes.indexOf` (index loops, never `unpack`, per
  `MicroHttp.Bytes`). Name bytes accumulate under `maxFieldBytes`; a name is small by construction.
- **At `=`**: decode the name, choose the sink, and switch to **in a value**.
- **In a value**: scan for `&`; feed the bytes before it to the part's sink as a chunk (an O(1) `BS.take`
  view), and the bytes after it are the next part. A chunk with no `&` is fed whole and the state persists.
- **At `&` or end of stream**: complete the part's sink with an orderly end of stream (`Iteratee.run` on
  the sink in its own right, not the outer stream's end), record its result, and continue.
- **A field with no `=`** is a name with an empty value, as the old parser produced. **An empty field**
  between two `&` is a field with an empty name. **An empty body** has no parts.

The sink for a part is driven with `Iteratee.feedChunk` (RFC-0040 phase 9), which feeds a chunk without
closing the sink, exactly the mechanism the streamed diff uses to interleave several sources into one body,
here used to interleave one source into several sinks. A part sink that fails (an over-cap file sink, a
transport error) fails the form consumer with that error, so the middleware's failure handling answers as
it does today (`413` for the too-large class). The residue of a failed form is not meaningful: the server
answers the error and closes the connection without resuming the stream (review, 2026-09-13). A part whose
value was streaming when the stream itself failed is handed the failed end before the form fails, so a
file sink closes and removes its temp.

`decodeFormValueI`'s carry is at most two bytes: a `%` with zero or one hex digits seen at a chunk end. A
`+` needs no carry. A malformed escape passes through verbatim, as the old decoder did. Because decoding is
per byte and the output goes to the sink chunk by chunk, no value-length list exists, which is the fix for
the decoder ceiling.

### What Verso does with it

`treeSave` becomes

```haskell
(fields, sunk) <- Http.formI saveLimits tooLarge route
  where
    route name
        | name == "markdown" = SinkPart (decodeFormValueI (normaliseNewlinesI (Stream.fileSinkI formBodyLimit tooLarge tmp)))
        | otherwise = CollectField
```

with `tmp` a temp beside the target (or under the draft root when versioning is on) and the rename into
place shared with the raw `PUT` (`sinkBodyToFile`'s tail). `normaliseNewlinesI` is the streaming form of
`normaliseNewlineBytes`: one byte of carry (a trailing CR waiting to see whether LF follows), CRLF and lone CR
both become LF. `normaliseNewlineBytes` and `parseFormBody`'s whole-body callers are retired once the
handlers move; the byte `decodeFormValueBytes` stays only if a caller still needs a value decoded in hand.

The identifier-only handlers (`treeCreate`, `treeMove`, `treeDelete`, `treeRollback`, `treeImageTitles`,
the client-error report) keep `formFields` over a small strict read: their bodies are capped at 8KB or 64KB
and are small by contract, and there is nothing to route. Their `formFields` can be reimplemented over
`formI` with every part `CollectField` so there is one parser, which is the deletion test for the old one.

### Sequencing constraint

A sink is chosen when the name arrives, so the decision cannot depend on a later field. The save form has
one large field and its other fields are read after the fact, so nothing depends on order today. The
constraint is recorded on `formI`'s Haddock and in `View.editorShell`'s form as a comment, so a future
control field is placed before the `<textarea>`.

## Alternatives Considered

- **Switch the save form to `multipart/form-data` and write only a multipart consumer.** The converged
  design in other frameworks is multipart-first, and a multipart part carries headers that make routing
  richer. Not chosen as the first step: the urlencoded state machine is smaller (no boundary search, no part
  headers), the save form is the only large-field form and it is urlencoded today, and the part interface is
  the same either way. Multipart is the reopen condition, not an alternative.
- **Stream the body to a temp file, then parse the file in blocks.** Removes the in-memory body but keeps a
  second pass and a temp file per form post, and the parse still has to route the large field somewhere;
  it is the same state machine with a disk round trip added. Not chosen.
- **A two-pass parse that first indexes `&` positions over the strict body, then decodes each value straight
  to its destination.** Keeps the whole-body `ByteString` (a malloc'd buffer outside the arena, so no GC
  pressure, per ADR-0088's finding), and only removes the decoded copies. Cheaper to write, but it leaves the
  last whole-body read in place and does nothing for a 10MB `max_body_bytes` form. Not chosen.
- **Raise the evaluator stack or find the depth accumulation in `decodeFormValueBytes`.** The stack is a
  runtime constant, and phase 2's block-decode experiment did not move the threshold; understanding it is
  worthwhile but is an mhs investigation, not a framework design. The streaming decoder makes the question
  moot for this path.
- **Do nothing.** The form is the no-JavaScript floor and its users write small pages. Rejected because the
  path is the last whole-body read, its decoder has a documented hard limit below the body cap, and the fix
  reuses machinery RFC-0040 already built.

## Security Impact

- The per-field and total collected caps close a gap the body cap alone leaves: a body under `formBodyLimit`
  can today be one field of that size, decoded whole. After this RFC an unrouted field is bounded by
  `maxFieldBytes` and the set of them by `maxCollectedBytes` (names and values together; the review found
  the first cut counted values only) and `maxFields`.
- A routed part is bounded by its own sink's cap (`fileSinkI`'s), which is where the page-size policy lives.
- No new parsing of untrusted structure beyond what `parseFormBody` already accepts; the same malformed
  escapes pass through verbatim. The name is decoded before it is compared for routing, so an encoded name
  routes as its decoded form, which is also what the old parser produced.

## Reliability Impact

- A part sink that fails mid-stream fails the whole form; the file sink removes its partial temp
  (`fileSinkI`'s contract), and nothing is renamed into place, so a failed save leaves the previous page.
- The temp-then-rename tail is shared with the raw `PUT`, so the atomic-replacement property is uniform
  across the three save paths.
- An interrupted client (connection drop mid-body) reaches the sink as a transport failure at end of stream
  and is cleaned up the same way.

## Compatibility Impact

- The urlencoded wire contract is unchanged; every body the old parser accepted decodes identically, which
  the golden tests below fix.
- Handlers see the same decoded fields for collected parts. The one observable change is that a field over
  `maxFieldBytes` that is not routed is refused (`413`) where today it was accepted up to the body cap. For
  the save form the only large field is routed, so nothing that works today stops working.
- `Http.parseFormBody` and `decodeFormValueBytes` are framework exports; they are retired when their last
  caller moves, with the `HttpSpec` contract tests moving onto `formI`.
- A form with two `markdown` fields saves the last one, where the whole-body parser's `captureBytes` took the
  first: each routed part opens the temp afresh. The browser form has one such field, so no client sees the
  difference (recorded by the review, 2026-09-13).

## Testing and Quality Gates

Test-first, ordered simplest to hardest. The unit suite is under `test/unit/MicroHttp/FormSpec.hs` and
runs under both compilers (`make test` and `make test-ghc`).

Decoder (`decodeFormValueI`), as a collecting sink, each compared with `decodeFormValueBytes` on the whole:

1. Given plain bytes, when decoded, then they pass through unchanged.
2. Given `+`, when decoded, then it is a space.
3. Given `%41`, when decoded, then it is `A`.
4. Given `%4` at the end of one chunk and `1` at the start of the next, when decoded, then it is `A`.
5. Given `%` alone at a chunk end and two non-hex bytes following, when decoded, then all three pass through.
6. Given `%C3%A9` split at every boundary, when decoded, then the two UTF-8 bytes are emitted verbatim.
7. Given a value above the old 350KB ceiling, when decoded, then it completes and equals the oracle (the
   oracle is computed in pieces the old decoder can handle).

Parser (`formI` with every part `CollectField`), each compared with `parseFormBody` on the whole body,
delivered in chunk sizes 1, 2, 3, 7 and whole:

1. Given `a=1&b=2`, when consumed, then two fields in order.
2. Given `a=1=2`, when consumed, then the value is `1=2` (only the first `=` separates).
3. Given `a`, when consumed, then the value is empty.
4. Given `a=1&&b=2`, when consumed, then the middle field has an empty name.
5. Given an empty body, when consumed, then no fields.
6. Given a `&` at a chunk boundary and an `=` at a chunk boundary, when consumed, then the fields are cut
   correctly.

Routing and caps:

1. Given a route that sinks `markdown`, when consumed, then the collected fields exclude it and the sink
   receives its raw bytes in arrival order.
2. Given a collected field over `maxFieldBytes`, when consumed, then the consumer fails with the supplied
   error (the residue of a failed form is not meaningful; see the Proposal).
3. Given fields whose decoded total exceeds `maxCollectedBytes`, when consumed, then it fails.
4. Given more than `maxFields` fields, when consumed, then it fails.
5. Given a routed sink that fails on its second chunk, when consumed, then the form fails with that error.

Newline normalisation (`normaliseNewlinesI`), compared with `normaliseNewlineBytes`:

1. Given CRLF, lone CR, and a CR at a chunk end followed by LF at the next chunk start, when normalised,
   then each is one LF.

Integration (`test/integration/Verso/AppSpec.hs`):

1. Given a form save whose `markdown` is larger than any stream chunk and contains every escape class, when
   posted, then the page on disk equals the old path's output byte for byte.
2. Given a form save over `formBodyLimit`, when posted, then it is refused, the page is unchanged, and no
   temp file is left beside it.
3. Given versioning on, when a form save is posted, then the draft is staged from the stream and the live
   page is unchanged.

Gates: `make check` green under both compilers; the `HttpSpec` contract tests for the byte parser move to
`FormSpec` when the parser is retired.

## Rollout Plan

### Phase 1: the decoder and the parser

- [x] `MicroHttp.Form` with `decodeFormValueI`, `normaliseNewlinesI` (framework-level, since it is a plain
      byte transform), `FormLimits`, `PartSink` and `formI`, driven by the unit tests above. **Done
      (2026-09-13.)** Both transformers share one `transformI` (block step plus a small carry); the decoder
      finds its carry by the same left-to-right walk it decodes with, so an escape's bytes are never split and
      a `%` that is the tail of a malformed escape is not mistaken for a carry. `maxFields` counts every part,
      routed or collected.
- [x] `HttpSpec`'s `parseFormBody` contract cases re-expressed as `formI` all-collect cases, side by side
      with the old parser, so the two are proven equal before anything moves. **Done (2026-09-13.)** The
      `FormSpec` oracles are written over `String`, independent of both parsers, and every case is fed at
      chunk sizes 1, 2, 3, 5, 7, 64 and whole. Note: `HttpSpec` already decoded a 1 MiB value through
      `parseFormBody` in one piece, so the "350KB ceiling" in `decodeFormValueBytes`'s comment does not
      reproduce there; the streaming decoder bounds each decode by a block regardless, and the comment is
      retired with the function in phase 3.

### Phase 2: the save form

- [x] `treeSave` routes `markdown` to a decoded, normalised file sink and renames into place through the
      tail shared with `sinkBodyToFile`; both the versioning-on (draft) and versioning-off (page) branches.
      **Done (2026-09-13.)** The shared tail is `sinkToFile`, which reserves the temp, runs any consumer
      built for it, and renames; `Iteratee.onFailure` (new, tested) removes the temp when the consumer or
      the stream fails part-way, which `fileSinkI` alone could not cover once the form's other fields could
      fail after the document had been sunk. The temp is created empty first so a form with no `markdown`
      saves an empty page, as before.
- [x] The three integration tests above. **Done (2026-09-13.)** Plus a fourth: a non-document field over
      the field cap is refused and leaves no temp. Finding: the test harness (`respondToRequestBytes`) feeds
      the whole request as one chunk, and the first run crashed the suite on the 400KB form, because a block
      step's per-block list was proportional to the chunk. `transformI` now slices every chunk to 4KB before
      the block step, so the slice, not the producer, bounds each intermediate; two unit cases fix it (a 1.4MB
      single chunk, and escapes straddling every slice boundary).
- [x] The sequencing constraint recorded on `formI` and beside the form in `View.editorShell`. **Done
      (2026-09-13.)**

### Phase 3: retire the whole-body parser

- [x] `formFields` reimplemented over `formI` all-collect for the identifier handlers. **Done (2026-09-13.)**
      As `formFieldsI cap`, which consumes the body directly (no strict read first): the per-field and total
      caps are the handler's old body cap, and the count cap is the cap plus one, which catches the one
      shape the byte total cannot: a run of empty fields, which add no bytes (the review corrected the
      first wording, which claimed the bytes alone implied the count). Six handlers moved (create, move,
      undo, client error, image titles, rollback).
- [x] `Http.parseFormBody`, `decodeFormValueBytes` and `App.normaliseNewlineBytes` removed with their tests
      moved; the KNOWN CEILING note retired. **Done (2026-09-13.)** `App.captureBytes` went with them. The
      `String` `decodeFormValue` stays for query strings. RFC-0040's inventory row is **not** edited: the RFC
      is implemented and `docs/README.md` makes implemented RFCs point-in-time; its `treeSave` row already
      hands the whole-body read to this RFC, and this checklist is the record of the fix.
- [x] ADR: form bodies are consumed as routed part streams (a load-bearing framework contract in the ADR-0091
      family), recording the sequencing constraint. **Done (2026-09-13.)** ADR-0092, which also records the
      producer-chunk slicing rule phase 2 found.

### Findings from the phase 3 gate (2026-09-13)

The first full `make check` after phase 3 failed the GHC editor smoke five runs in six, with the client
reporting a closed socket on the `?raw` poll right after a save. Bisection with GHC builds at earlier
commits placed the regression at the raw `PUT` streaming change (cbc4208, an RFC-0040 follow-on), not at
this RFC; the mhs smoke never failed, and neither `curl` nor a bun client could reproduce it in isolation.
The access log gave the mechanism: the concurrent `?raw` GET resolved the page's size for its `FileBody`
(`Socket.fileSizeBytes`), the PUT then renamed the new page into place, and the sink `sendfile`d the new
inode under the old `Content-Length`, so the client received a short body and a close. In-place
`BS.writeFile` had the same race with a window too small to hit; atomic replacement widened it to the
handler's whole duration. Fixed in `Server.socketSinkFile`: the head's length is now the size of the file
the sink actually opened (one `lseek`), so head and body agree whatever happened to the path in between;
two socket-level tests cover a file replaced by a shorter and a longer one. The carried size still feeds the
access log, which may be stale by design. Recorded here because this RFC's gate found it; the fix is its
own commit.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if another RFC owns the
  contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user approval.

## Open Questions

- Whether `normaliseNewlinesI` belongs in the framework (a generic byte transform, beside
  `decodeFormValueI`) or in Verso (a document-contract rule). Proposed: framework, since it has no Verso
  vocabulary and the framework already owns the decoder.
- Whether the collected-field caps should default from `FormLimits` constants in the framework or be passed
  by every caller. Proposed: passed, with Verso holding one `saveLimits` beside `formBodyLimit`.
- Whether to take the multipart parser in the same RFC once the part interface exists. Proposed: no; record
  it as the reopen condition and take it when a multipart form appears.
- Whether a save form with no `markdown` field should save an empty page (parity with the whole-body
  parser) or be refused with a `400`. Decided (review, 2026-09-13): keep the parity. The only producer is
  the server's own form, which always carries the field, so the stricter contract would guard nothing, and
  the empty temp is what makes the rename tail uniform with the raw `PUT`.
