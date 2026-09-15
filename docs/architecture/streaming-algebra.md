# MicroHttp Streaming Algebra

How bytes move through the framework and the application without ever being held whole, stated once
as a small algebra so that "is this pipeline already designed?" is answerable from one page. It covers
`MicroHttp.Iteratee`, `MicroHttp.Stream`, `MicroHttp.Form`, the response body types in `MicroHttp.Http`,
and the application consumers built on them. The decision that streaming is the default is ADR-0091;
the recipes for a handler author are in [Streaming I/O Recipes](../guides/streaming-io.md); this page
is the explanation behind both. It is living.

Change plans referenced here:

- [RFC-0004](../rfcs/implemented/rfc-0004-iteratee-streaming-io.md) introduced the core.
- [RFC-0014](../rfcs/implemented/rfc-0014-zero-copy-file-responses.md) added `sendfile` file bodies.
- [RFC-0039](../rfcs/implemented/rfc-0039-constant-space-document-handling.md),
  [RFC-0040](../rfcs/implemented/rfc-0040-constant-space-request-and-response-paths.md) and
  [RFC-0042](../rfcs/implemented/rfc-0042-streaming-form-consumer.md) moved the document, request,
  response and form paths onto it.
- [RFC-0041](../rfcs/implemented/rfc-0041-multi-source-iteratees.md) made the effect layer a parameter
  and added the two-source driver.
- [RFC-0043](../rfcs/implemented/rfc-0043-streaming-io-by-default.md) added the folds over files and
  subprocess output, the lint gate and the memory benchmark.

## Streaming Model in One Paragraph

The design is Oleg Kiselyov's iteratee model: consumer-centric and push. A consumer (an iteratee) is a
value in one of four states: done with a result and a residue, waiting for input with a pure
continuation, mid-effect, or failed with a typed error and a residue. A producer (an enumerator) is a
function that drives a consumer forward by feeding it chunks and resolving its effects, and returns the
consumer's final state; a driver turns that final state into a result. The producer owns any resource
the bytes come from and releases it on every exit, including a consumer that stops early or fails. The
`streaming` and `conduit` families are the other shape, producer-centric and pull, where the stream is
a value and the consumer is a fold over it; the differences and why we keep this shape are in
"Comparison with the streaming library" below.

## Streaming Algebra

Four kinds of thing, and every pipeline in the tree is one of each, composed in the one way the types
allow: a source drives a sink, possibly through transformers, under a driver.

| Kind        | Type                                                 | Role                                                                                |
| ----------- | ---------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Source      | `EnumeratorT e m a = IterT e m a -> m (IterT e m a)` | Feeds chunks to a consumer and resolves its effects; owns and releases its resource |
| Sink        | `IterT e m a`                                        | Consumes chunks to a result of type `a`, or fails with an `e`                       |
| Transformer | `IterT e m a -> IterT e m b`                         | Wraps a sink so it sees a different stream: bounded, decoded, normalised, mapped    |
| Driver      | `run`, `runNested2`                                  | Turns a driven consumer into `Either e a`, delivering the final end of stream       |

`Iter e a` and `Enumerator e a` are the `IO` instances, which is every producer and consumer at the
socket and HTTP boundary. In the literature a transformer is an enumeratee; this page uses transformer
because that is what the code calls its instances.

### Streaming Sources

| Source                                                | Resource and release                                                                 | Module     |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------ | ---------- |
| `strictEnumerator bytes`                              | none; one chunk then end of stream                                                   | `Iteratee` |
| `resourceEnumerator acquire release read err`         | the generic bracket every other producer is built on                                 | `Iteratee` |
| `fileEnumerator path`, `fileEnumeratorChunked n path` | a file handle, chunks of `fileChunkBytes` or `n`                                     | `Stream`   |
| `tempFileEnumeratorChunked n path`                    | as above, and the file is removed when the producer returns, however it returned     | `Stream`   |
| `socketEnumerator socket bufferBytes idleMicros`      | a client socket read with an idle timeout; the caller closes the socket              | `Stream`   |
| `transformedFileBody before transform after n path`   | a file handle, each block passed through `transform`, with a prefix and suffix       | `Stream`   |
| `transformedTempFileBody`                             | as above, and the file is removed once the body is produced or the consumer stops    | `Stream`   |
| `appendEnumerators sources`                           | each source in turn under its own bracket; the consumer sees one stream with one end | `Iteratee` |

`resourceEnumerator` is the resource-bracketing guarantee written once: acquire, then read until empty
or until the consumer resolves, then release, on every path. It runs at any layer whose base monad can
release on its own failure (`MonadRelease`), which is what lets the same bracket feed either stream of a
two-source consumer (RFC-0041 and its review).

### Streaming Sinks

| Sink                                   | Result                                              | Module                                     |
| -------------------------------------- | --------------------------------------------------- | ------------------------------------------ |
| `headChunk`                            | the next non-empty chunk, or `Nothing` at the end   | `Iteratee`                                 |
| `readBodyStrict err limit`             | the whole stream as bytes, failing past `limit`     | `Iteratee`                                 |
| `byteSinkI write`                      | each chunk handed to an effectful writer            | `Iteratee`                                 |
| `socketSinkI socket`                   | each chunk sent on a socket                         | `Stream`                                   |
| `fileSinkI limit err path`             | each chunk written to a file, the byte count        | `Stream`                                   |
| `frameHeadersI limits`                 | the request head, the body left as residue          | `Http`                                     |
| `formI limits err route`               | a multipart or urlencoded form, part by part        | `Form`                                     |
| `blockI`                               | a leading frontmatter block, capped                 | `Verso.Frontmatter`                        |
| `linksI`, `rewriteLinksI decide write` | a page's links; a page rewritten link by link       | `Verso.DocumentLinks`, `Verso.LinkRewrite` |
| `operationsI`                          | the operation log's entries                         | `Verso.OperationLog`                       |
| `equalBlocks`                          | whether two streams are byte-identical (two-source) | `Stream`                                   |

A sink that needs an effect between reads lifts it with `liftIO`; a sink that needs to read a second
stream nests it as its base monad and reads that stream through `lift` (`equalBlocks`).

### Streaming Transformers

| Transformer                         | Effect on the stream the inner sink sees                                                    | Module     |
| ----------------------------------- | ------------------------------------------------------------------------------------------- | ---------- |
| `takeN n inner`                     | at most `n` bytes, then end of stream; the rest stays as residue                            | `Iteratee` |
| `onFailure cleanup inner`           | unchanged; runs `cleanup` once if the inner fails or its base layer or an effect step does  | `Iteratee` |
| `decodeFormValueI inner`            | urlencoded bytes decoded, slice by slice                                                    | `Form`     |
| `normaliseNewlinesI inner`          | `\r\n` and `\r` become `\n`, slice by slice                                                 | `Form`     |
| `mapChunksI blockStep finish inner` | the general block-wise rewrite with a carry the two above are instances of; slice-bounded   | `Iteratee` |
| `linesI inner`                      | one terminated line per chunk, the final unterminated line last; the carry is the open line | `Iteratee` |

A transformer is a function from sink to sink: it intercepts `NeedInput`, rewrites or bounds what it
passes on, and leaves `Done` and `IterFailed` alone. Transformers compose by application, innermost
first: `normaliseNewlinesI (decodeFormValueI (fileSinkI ...))` is a file sink that sees decoded,
newline-normalised bytes. The form consumer routes each part to a sink built this way.

### Streaming Drivers and Folds

`run` resolves a driven consumer to `Either e a`, delivering the final end of stream itself so that a
sequence of producers can feed one consumer (`feedChunk`) and the end arrives once. `runNested2` drives a
two-source consumer from two enumerators. On top of these, `MicroHttp.Stream` gives the shapes a caller
usually wants without naming a sink at all: `foldFileBlocks`, `foldFileLines`, `fileContains`,
`filesEqual`, `copyFile`, `writeFileLines`; and `Process.withCapture` brings a subprocess's output into
the same folds by leaving it in a file.

## Streaming Pipelines in the Tree

Every byte path in the server is one row of this table. The columns are the algebra's kinds.

| Pipeline | Source | Transformers | Sink |
| --- | --- | --- | --- |
| Read a request | `socketEnumerator` | | `frameHeadersI`, then the handler's sink on the residue |
| Upload an asset to disk | `socketEnumerator` | | `fileSinkI` into a temp beside the target |
| No-JS form save | `socketEnumerator` | `normaliseNewlinesI`, `decodeFormValueI` per part | `formI` routing the `markdown` part to `fileSinkI` |
| Serve a document page | `appendEnumerators` of the shell prefix, the file (the escaper per block) and the suffix | | `byteSinkI` over the socket |
| Serve a static or asset file | `FileBody` (no Haskell in the loop: `sendfile`) | | the kernel |
| `transformedTempFileBody` | as above, and the file is removed once the body is produced or the consumer stops | `Stream` | |
| `appendEnumerators sources` | each source in turn under its own bracket; the consumer sees one stream with one end | `Iteratee` | |
| Serve a diff | `foldFileLines` over the git capture into a `StreamBody` | | `byteSinkI` over the socket |
| Compare two assets | two `fileEnumeratorChunked` (`runNested2`) | | `equalBlocks` |
| Copy an asset | `fileEnumerator` | | `byteSinkI` over `hPut` |
| Rewrite a page's links on move | `fileEnumerator` | | `rewriteLinksI` into a temp, then rename |
| Build or refresh the link index | `fileEnumeratorChunked` per page | | `linksI` |
| Load the persisted link index | `fileEnumeratorChunked` | `linesI` | a row parser as the step (`foldFileLines`) |
| Page history | `Process.withCapture` and `foldFileLines` | | a log-line parser as the step |
| Index a page for search | `foldFileLines` | | the chunker's `feedLine` as the step |
| Fingerprint a page | `foldFileBlocks` | | a hash step |

The two directions the question "does it compose?" usually asks about are the first and fourth rows:
receiving a body into a file is the socket source driving the file sink, and serving a file is the file
source driving the socket sink. Nothing in either is special-cased; the special case is `FileBody`,
which hands the whole transfer to `sendfile` because the kernel does it better than any Haskell loop.

## Streaming Invariants

- **The producer releases.** Whatever the consumer does, the enumerator that opened a handle closes it.
  A consumer never opens what it reads. This is why the tree has one `bracket` (in
  `resourceEnumerator`) rather than one per reader.
- **Failure is a value with residue.** `IterFailed e residue` keeps the unconsumed input so a keep-alive
  loop or a handler can decide what to do with it; nothing throws to signal end of data. Exceptions from
  effect steps are still exceptions, and `onFailure` and `MonadRelease` run cleanups on that path too.
- **Continuations are pure.** `NeedInput` carries a pure function, so the monad instance can feed
  residue eagerly; effects live only in `IterM`. An effectful continuation deadlocks a consumer that
  could complete from residue alone.
- **A slice bounds every intermediate.** A transformer works a chunk in slices of a fixed size and never
  builds a list proportional to a chunk (`Form.sliceBytes`), because on MicroHs a list proportional to a
  whole-body chunk overflows the evaluator stack. The same rule is why `MicroHttp.Bytes` exists.
- **Bytes stay bytes, and text is decoded.** Nothing decodes a document to `String`; only short pieces (a
  heading, a title, a field name) are decoded, at the point of use, through `MicroHttp.Utf8`. A `String`
  built by `BS.unpack`, one `Char` per byte, never travels past the call that decodes it.

## Comparison with the streaming library

`streaming` (and `streaming-bytestring`) is the other shape. Its core is `Stream (Of a) m r`, a free
monad whose steps yield elements or run effects; a producer is a value, consumers are folds over it,
producers compose by monadic bind and by stream-to-stream functions, and two sources combine with a
zip. Failure is an exception or whatever is put in `r`; resource release is external, a `bracket` or
`ResourceT` around the fold.

What it does better: expressiveness. Splitting, mapping, grouping, chunking and zipping are library
functions where we write each transformer by hand, and a two-source consumer is a zip rather than the
nested-layer construction of RFC-0041.

What this design does better for this codebase: the release contract is structural rather than a
discipline (a `Stream` that escapes its `bracket` unconsumed is the classic leak), the failure type and
residue are explicit, and the whole core is one small module that builds and benches under MicroHs.

Why we do not adopt it: it does not build under MicroHs (the MicroCabal package list marks `streaming`,
`streaming-bytestring` and their `mmorph` dependency as not building); the bridge is one-way (a `Stream`
becomes an enumerator by driving the consumer with each element, but an enumerator becomes a `Stream`
only by inverting push into pull, which needs a thread or continuation tricks), so adoption would be a
rewrite of the socket and file layers; and a free monad allocating a node per element is the kind of
cost RFC-0041 had to measure for a single dictionary. What is worth borrowing is the vocabulary, which
this page does, and a few combinators, listed next.

## Streaming API Gaps

Judged against the pipelines above and the ones a wiki is likely to need next, not against the
`streaming` catalogue.

- **Closed 2026-09-15.** Three gaps this page first listed are now in the core: `mapChunksI` (the
  block-wise transformer with a carry, moved out of `Form`, where the decoder and newline normaliser
  instantiate it), `linesI` (one line per chunk, which `foldFileLines` is now built on), and
  `appendEnumerators` (which replaced the phase machine inside `transformedFileBody`). `blockI` keeps
  its own carry because its cap and its whole-block classification are about the block, not the lines.
  The escaper's body producer still transforms inside its read step because the escaper is an `IO`
  block function and `mapChunksI` is pure; an `IO` variant is the next combinator if a second such
  transformer appears.
- **`runNested2` only.** A three-source consumer or a merge with an output sink is the same
  construction one layer deeper; the arity-specific driver is written when a consumer appears
  (ADR-0091, "Reopens when").
- **No pull-side adapter.** Nothing turns an enumerator into something a caller can step. The tree has
  not needed it; the form consumer is the closest, and it stays push.

What is not missing, and should not be copied from `streaming`: element-typed streams (everything here
is bytes, by design), a `ResourceT`, and a large combinator surface. Each combinator is a dictionary
and an allocation per chunk under MicroHs, and the tree's rule is that a pipeline is written from one
source, one sink, and the fewest transformers that make it correct.
