# RFC-0039 Memory Profile (2026-09-10)

Supporting evidence for [RFC-0039](../implemented/rfc-0039-constant-space-document-handling.md). Records how the
running server reaches ~900MB resident and where the non-constant-space code is. Measured on macOS arm64
with `ps`, `vmmap`, `footprint`, and `heap` against `build/verso`.

## The MicroHs heap is a fixed, non-growable arena

From the mhs runtime (`~/.mcabal/.../runtime/eval.c`):

- `#define HEAP_CELLS 50000000`, and `ALLOC_HEAP(n)` is `cells = mmalloc(n * sizeof(node))`, run once at
  startup. `sizeof(node)` is 16 bytes (two pointers), so the default heap is 50,000,000 x 16 = **763MB**.
- The GC marks and sweeps within that arena; when it cannot free enough it is a fatal `ERR("heap
  exhausted")`. There is no realloc or growth.
- `+RTS -H<cells> -RTS` sets the cell count. There is no environment-variable route (the runtime only
  exposes `getenv` to Haskell code, not to its own RTS parsing), so the heap is a command-line concern and
  cannot be a config-file key (the arena is allocated before the config is read).

`heap build/verso` on a warmed server shows a single ~781MB malloc node (the arena); the tens of thousands
of tiny nodes are the ONNX/abseil/protobuf C++ objects and sum to ~40MB.

## It is the arena, not ONNX

`vmmap -summary` on a warmed search-enabled server (~1.0G resident):

| Region         | Resident | What                                                         |
| -------------- | -------- | ------------------------------------------------------------ |
| `MALLOC_LARGE` | 769MB    | the mhs heap arena                                           |
| `__TEXT`       | 169MB    | shared code of ONNX Runtime and its abseil/protobuf/re2 deps |
| `MALLOC_SMALL` | 36MB     | C++ objects                                                  |
| other          | small    |                                                              |

The ONNX model (32MB) is mmap'd and mostly clean/shared. So the bulk is the mhs heap, which becomes
resident as the GC sweeps across it under allocation churn. RSS is not monotonic: it fell 878MB -> 310MB
after a GC, so the runtime does return pages.

## Heap size drives footprint

Search-demo corpus (163 documents), heap size versus steady footprint after a burst of searches:

| `-H` cells | heap bytes | footprint | note           |
| ---------- | ---------- | --------- | -------------- |
| 50,000,000 | 763MB      | ~900MB    | default        |
| 10,000,000 | 153MB      | ~220MB    | search works   |
| 4,000,000  | 61MB       | ~125MB    | works          |
| 2,000,000  | 31MB       | (crash)   | heap exhausted |

Footprint scales with heap size because the arena is mostly garbage not yet collected; the true live set is
small. Shrinking the heap directly cuts footprint, bounded below by the peak working set.

## Real corpus: the non-constant-space paths

`cello-docs`: 3980 documents, 2.3GB, largest single document 263KB. Search **off**, to isolate serving and
the link index:

- Startup builds the link index over all 3980 documents in 7.4s and sits at **847MB footprint** at ready
  (reload path ~790MB). This is the O(corpus) cost, not ONNX.
- `GET ...?raw` (sendfile / `FileBody`): footprint **flat** -- serving files is constant-space, confirmed.
- `GET ...?edit` on the 263KB document: footprint **+50MB per request** -- roughly 190x the document size,
  transient.
- Heap floor for the real corpus (survives the build plus large-document edits):

  | `-H` cells | footprint at ready | after big-doc edits |
  | ---------- | ------------------ | ------------------- |
  | 8,000,000  | 142MB              | 198MB               |
  | 16,000,000 | 276MB              | 341MB               |
  | 24,000,000 | 400MB              | 533MB               |

  All three survive; 8M is comfortably above the floor, versus ~790MB at the 50M default.

## Root causes (whole-file / whole-document in the Haskell heap)

- `MicroHttp.Html.escapeBytes` / `escapeChars`: `BS.pack (concatMap escapeChar (BS.unpack input))` unpacks
  the whole content ByteString into a `String` to escape it -- the +50MB-per-edit spike, since `bytesText`
  embeds document content in the editor page.
- Link-index cold build: `LinkIndex.buildIndex :: [(PagePath, BS.ByteString)] -> LinkIndex` folded over a
  list the caller materialises fully (`LinkIndexStore` "single walk (forced)") -- every document body
  resident at once.
- Frontmatter-title lookups: `frontmatterTitle` / `readDocumentText` / `breadcrumbsFor` /
  `documentPageTitle` unpack the whole document to read the small frontmatter block.
- `MicroHttp.Log` reads a whole log file only to measure its length (should `stat`); `Verso.OperationLog`
  reads and unpacks the whole operation log.
