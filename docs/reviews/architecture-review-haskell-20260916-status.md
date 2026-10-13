# Haskell Architecture Review Status (2026-09-16)

This file tracks what became of each candidate and noted item in
[`architecture-review-haskell-20260916.html`](architecture-review-haskell-20260916.html), the architecture
review of the Haskell tree taken at `main @ 4c061f6`. File and line numbers in the review refer to that commit,
not to the current tree.

The review is point-in-time and is not edited. This file is its living companion: update the row when a
candidate's status changes, and cite the RFC, ADR or commit that changed it. Statuses are Done, In progress,
Won't do (with the record that declined it) and Open.

## Haskell Architecture Review Candidate Status

| # | Candidate | Status | Evidence | Note |
| --- | --- | --- | --- | --- |
| 1 | One module for the tree's structural operations | Done | [RFC-0045](../rfcs/implemented/rfc-0045-structural-operations-module.md), `38fa074`, [code review](rfc-0044-0045-code-review-20260916.md) | `Verso.Structure` owns move, delete, restore and undo. A pure preview/apply plan was a non-goal. |
| 2 | The tree layout as a module: page path, section path, meta directory, peer assets | Done | [RFC-0044](../rfcs/implemented/rfc-0044-tree-path-module.md), `506fbef`, `44fae79`, [code review](rfc-0044-0045-code-review-20260916.md) | `Verso.TreePath` with one `TreePath` type and `TrashId`, not separate page and section types. The MicroHs non-ASCII file-name decision was left as a seam. |
| 3 | Trash in one module, not three | Done | [RFC-0047](../rfcs/implemented/rfc-0047-trash-owns-its-mechanics.md), `577c28a`, [code review](rfc-0046-0047-code-review-20260916.md) | Entry mechanics moved to `Verso.Trash`; `TrashStore` now imports `Trash`, not `TreeMove`. The warm catalogue stays a separate module by design; retention moved to `Structure` in RFC-0045. |
| 4 | The framework joins body types to body producers, not the application | Done | [RFC-0049](../rfcs/implemented/rfc-0049-framework-streamed-response-constructor.md), `c1e97aa`, `83a7b9f`, [ADR-0034](../adrs/adr-0034-zero-copy-file-responses-via-sendfile-with-the-size-carried.md) (amended), [code review](rfc-0049-code-review-20260917.md) | Framework constructors and `mapBody` in `MicroHttp.Http`. The carried `FileBody` size is recorded as advisory. A chunked file-response variant is deferred until a caller needs it. |
| 5 | One consumer idiom in the core; Form and Http share one decoder | Done | [RFC-0050](../rfcs/implemented/rfc-0050-one-consumer-idiom-in-the-streaming-core.md), [ADR-0095](../adrs/adr-0095-percent-decoding-follows-the-whatwg-recovery-rule.md), `c9debe8`, [code review](rfc-0050-code-review-20260917.md) | One percent-decoder in `MicroHttp.Percent`. Three of five consumers use `foldChunksI`; the cap and the file sink were declined (RFC-0050 phases 3 and 4). |
| 6 | JSON as a value, rendered once | Done | [RFC-0046](../rfcs/implemented/rfc-0046-json-value-type.md), `ca3428b`, `52bfd4e`, [code review](rfc-0046-0047-code-review-20260916.md) | `Verso.Json` value type with one renderer. The persisted operation-log line format is unchanged (non-goal). |
| 7 | Html: shrink the interface, one escaper contract | Done | [ADR-0094](../adrs/adr-0094-one-spelling-of-the-html-tag-combinators.md), `42bc130`, `4b6badc`, `ff5f411` | Duplicate tag aliases dropped and the two escapers pinned against each other by test. Routing `escapeChars` through `escapeBlockBytes` was declined in ADR-0094 (needs a benchmark and an ADR-0086 amendment). |
| 8 | Search runtime and Git: seams that exist but have one adapter | Done | [RFC-0048](../rfcs/implemented/rfc-0048-maintenance-events-and-git-results.md), [ADR-0093](../adrs/adr-0093-git-operations-surface-failures-as-typed-results.md), `3d92565`, `288ea53`, [code review](rfc-0048-code-review-20260916.md) | Typed `Maintenance.Event` and Git `CommitResult`. `logForPath` unchanged (non-goal). The search worker's own unit seam, which the review left undesigned, is still open. |

## Haskell Architecture Review Noted Item Status

| Noted item | Status | Evidence | Note |
| --- | --- | --- | --- |
| `Frontmatter` imports `SearchChunks` for `isDashesLine` alone | Done | `f619fa8` | Line scanning moved to a new `Verso.PageLines`, imported by both. |
| `Static.safeComponent` cited as the validator but private | Done | [RFC-0044](../rfcs/implemented/rfc-0044-tree-path-module.md) | Exported by RFC-0044. |
| `Router.notFound` and `Static.notFoundResponse` are the same response | Done | `f619fa8` | `Static.notFoundResponse` removed; `Router.notFound` is the framework 404. |
| Access log decodes the target byte per `Char`; `pathSegments` decodes UTF-8 | Won't do | `f619fa8` | Deliberate: the log records what the client sent. The reason is now documented in `Middleware`. |
| `Html`, `Router`, `Server`, `Network.Socket` have no Haddock module header | Done | `f619fa8` | Headers added. |
| `Server.reportConnectionFailure` writes to stderr outside the Logger | Won't do | `98b0c46` | Kept on stderr; the reason is recorded at the definition in `Server.hs`. |
| Runtime gaps (an `IO` `mapChunksI`, `runNested3`, a pull cursor) | Open | [streaming-algebra.md](../architecture/streaming-algebra.md) | Deferred by the review itself until a caller needs one; tracked on the architecture page. |

## Haskell Architecture Review Remaining Open Items

All eight candidates are done. These parts were left open or deferred on purpose:

- The search worker's unit seam (candidate 8). `Verso.SearchIndex` still has no unit spec.
- A chunked file-response constructor (candidate 4), deferred in RFC-0049 until a caller needs one.
- The MicroHs non-ASCII file-name route (candidate 2), deferred in RFC-0044;
  see [microhs-filepath-encoding-bug-report.md](microhs-filepath-encoding-bug-report.md).
- The runtime gaps in the noted items, tracked in `docs/architecture/streaming-algebra.md`.
