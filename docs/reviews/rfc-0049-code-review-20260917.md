# RFC-0049 code review: framework streamed-response constructor

Status: review (2026-09-17). Change set: `5366dde..c1d2d24` on `main`, four commits (a Draft RFC, two
code phases, the records). About 175 insertions and 40 deletions across five source and test files:
`MicroHttp.Http` gained `transformedFileResponse`/`transformedTempFileResponse`/
`transformedBytesResponse` (over a `BlockTransform`) and `mapBody`; `Verso.App`'s document responses
collapsed onto them and `documentStreamedResponse` was deleted; `Middleware.fuseBody` reduced to a
`mapBody` adapter; the framework tests, the ADR-0034 amendment and the architecture records.

The review ran along the two usual independent axes, each in its own sub-agent: Spec (does the code do
what RFC-0049 and the ADR-0034 amendment say, and are the documents accurate) and Standards (documented
conventions and the Fowler smell baseline). A third sub-agent traced correctness, concentrating on
byte-for-byte parity of the three document responses against the pre-change code and on the temp-file
cleanup. The sections are not reranked. Each finding is labelled MEASURED, VERIFIED or INFERRED.

Baseline for the review, all MEASURED at `c1d2d24`: `make check` passes in full (mhs unit 615, mhs
integration 165, the same under GHC, the editor checks, both smokes, the chrome gates).

## RFC-0049 Correctness Findings

No correctness defects. The refactor is byte-for-byte faithful.

### Correctness 1: the three document responses are byte-identical

VERIFIED by textual comparison against `git show 5366dde`.

`documentFileResponse` and `documentTempFileResponse` pass the same prefix (`documentShellBytes`,
including the doctype), suffix (`BS.concat (Html.renderChunksRaw ...)`), block size (`docBlockBytes`),
transform (`Html.escapeBlockBytes`) and length (`Html.escapedLength`) that the old
`documentStreamedResponse` used, so the streamed bytes and the summed `Content-Length` are identical.
`documentBytesResponse` through `transformedBytesResponse` produces the same
`concat [shell, escaped, suffix]` under the same `SizedStreamBody (BS.length body)`. The count fold
(`(n +) <$> btLength`) matches the old `addEscapedLength`.

### Correctness 2: the missing-file and temp-cleanup semantics are preserved

VERIFIED. `Stream.foldFileBlocks` returns `Left` on a missing file rather than throwing, so
`Exception.onException` fires only on a genuine throw and the `Left` branch runs the cleanup once (my
review prompt's worry about a double removal was unfounded, and a `removeFilePath` on a vanished file is
a harmless `Left` either way). On success the temp is removed by `transformedTempFileBody`'s
`removingOnReturn`, not the constructor, as before. `orNotFound`'s two-clause match is equivalent to the
old inline `Left -> treeNotFound`.

### Correctness 3: mapBody equals the old fuseBody, and its size caveat is pre-existing

VERIFIED. `mapBody`'s four arms are behaviourally identical to the old `fuseBody`: strict and file
bodies unchanged, the stream and sized arms wrap the enumerator, the sized size preserved.
`fuseBody = Http.mapBody fuse` wraps exactly as before. The property that a `SizedStreamBody`'s
`Content-Length` is preserved even if an egress stage changes the byte count is pre-existing (the old
`fuseBody` did the same) and documented on `mapBody`; the `BlockTransform` contract
(`btLength b == fmap BS.length (btApply b)`) is the framework's guard for the document path, and the
escaper satisfies it.

## RFC-0049 Spec Findings

### Spec 1: an architecture-doc claim is overstated

VERIFIED. `docs/architecture/project-organisation.md` says the response-body taxonomy is matched only
inside `MicroHttp.Http` and that `MicroHttp.Middleware` no longer names the body constructors. The
access-log tap in `Middleware` (`MicroHttp/Middleware.hs:146-163`) still matches all four constructors
to size each body for the log. The narrower claim on `mapBody` -- that it is the one place an egress
stage *rewrites* a body -- is true; the flat statement in the architecture doc is not. Fix the wording
to distinguish the content rewrite (one place, `mapBody`) from the logging tap that still sizes each
body kind.

### Spec 2: the identity-transform test the RFC named is absent

VERIFIED. The RFC's Testing section names "an identity and a length-changing transform"; the tests use
only the length-changing `appendBang`. The length-changing case does pin the count-versus-bytes
invariant, so this is partial, not wrong. The temp "removes on failure" item is inherently untestable
as written (a nonexistent file cannot be removed); the code path is correct and the removal-after-serve
case is tested.

### Spec 3: everything else is faithful

VERIFIED. The constructor interface matches the RFC's proposed block; cleanup ownership is correct; all
three document responses route through the framework and `documentStreamedResponse` is gone; the diff
body and the four `ResponseBody` constructors are unchanged; the ADR-0034 amendment matches the code
(`Server.socketSinkFile` re-stats and writes the head with the re-read size, the carried size feeding
only the access log).

## RFC-0049 Standards Findings

No documented-standard violations and no hard smells. The three constructors, `BlockTransform` and
`mapBody` carry per-function Haddock; the new `Http` imports (`Control.Exception`, `Control.Monad`,
`MicroHttp.FileSystem`) are all used and introduce no cycle (`FileSystem` is a leaf); `Control.Exception`
was removed from `App` with no dangling reference. Two judgement calls, both left as they are:

- `BlockTransform` bundling three fields that travelled loose in the old six-argument
  `documentStreamedResponse` is a good data-clump fix with a stated invariant, not primitive obsession.
- `transformedBytesResponse` takes a plain transform function while its two file siblings take a
  `BlockTransform`; the asymmetry is defensible (in-memory content has no file count) but a reader holds
  two shapes. Acceptable.

`sizedFileResponse` (the shared private core of the two file constructors) and `orNotFound` (a
two-clause match, since mhs's `Data.Either` lacks `fromRight`) are both sound.

## Summary

Correctness: three sections, no defects, parity verified textually. Spec: three findings, the real one
being the overstated single-site claim in the architecture doc, contradicted by the logging tap; plus a
partial test the RFC named. Standards: no violations, two documented judgement calls.

## Remediation Summary

Applied on 2026-09-17. Both spec findings were addressed; every gate below was rerun.

### Remediation of the spec findings

- Spec 1 (fixed): `docs/architecture/project-organisation.md` now says an egress stage rewrites a body
  in one place (`Http.mapBody`, used by `Middleware.fuseBody`), that `writeResponse`/`serialiseResponse`
  dispatch the body kinds, and that the access-log tap in `Middleware` still matches them to size each
  body. The overstated "matched only inside `MicroHttp.Http`" wording is gone.
- Spec 2 (fixed): `test/integration/MicroHttp/Http/ResponseFileSpec.hs` gains the identity-transform
  case the RFC named, asserting the `Content-Length` is the prefix, file and suffix lengths and the
  bytes are unchanged, alongside the existing length-changing case.

### Findings left as they are

- The two Standards judgement calls (`BlockTransform` versus the plain transform of
  `transformedBytesResponse`; `mapBody`'s single caller) are documented, intended shapes.
- The pre-existing `mapBody` size caveat is unchanged and documented.

### Verification after remediation

MEASURED: `make format`, `make lint`, `make docs`, the mhs integration suite (166 examples) and the same
under GHC.
