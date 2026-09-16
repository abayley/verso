---
id: RFC-0046
name: JSON Value Type
status: In Progress
owners:
    - alistair
created: 2026-09-16
updated: 2026-09-16
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0045
---

# JSON Value Type

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-16 |
| Started   | 2026-09-16 |
| Completed |            |

## Summary

Render the wiki's JSON API responses from a value, not by string concatenation. `Verso.Json` holds a
small JSON tree (`JNull`, `JBool`, `JInt`, `JString`, `JArray`, `JObject`) and one `render`. The
domain renderers and the handlers build a `Json` value; the response boundary renders it once. The
escaping moves to one place and is corrected to the JSON specification. Nothing about the wire shape
changes except that a control character in a string is now escaped rather than emitted raw.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 6) found JSON built by string concatenation in three modules:

- `Verso.View` exports `jsonObject`, `jsonArray`, `jsonString`, `jsonBool`. `jsonObject` takes
  `[(String, String)]` where each value is _already-rendered_ JSON, so the type does not distinguish a
  string that must be escaped from a number or a nested object that must not. This is the leaky
  interface the review named.
- `Verso.TreeMove` has its own `jsonStr` (a byte-for-byte copy of `View.jsonString`) and three
  renderers (`movePlanJson`, `trashListJson`, `replayReportJson`).
- `Verso.App` has about 45 call sites through `View.json*` and eight body-rendering functions
  (`createdJson`, `deletedJson`, `restoredJson`, `undoneJson`, `referrersJson`, `trashEntriesJson`,
  `treeChildrenJson`, `searchResultsJson`).

Two of the review's Standards findings are the same observation: the duplicated `jsonStr`, and the
kind travelling as a string into these renderers. The escaper in both copies handles only `"`, `\`,
`\n`, `\r`, `\t`; a string carrying any other control character (below U+0020) produces invalid JSON.

RFC-0045 gave the structural operations typed outcome records; those records are exactly what should
convert to a `Json` value in the handler.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it as complete in the
phase checklist.

## Goals

- One JSON representation and one renderer for every API response.
- One escaper, correct to the JSON specification.
- Domain renderers and handler bodies build a value; the response boundary renders it.
- No wire-shape change; the only behaviour change is correct escaping of control characters.

## Non-Goals

- The operation log format. `OperationLog.renderOperation` is the persisted log line
  (`appendOperation` writes it, `parseOperation` reads it back, replay depends on it), not an API
  response. It stays exactly as it is, and the `/operations` endpoint keeps splicing it.
- A JSON parser. Nothing in the tree reads JSON; the editor is the only reader and it is TypeScript.
- Numbers other than integers. Every number the API emits is an `Int` (a `seq`, a count, a pending
  total), so the type carries `JInt Int` and no floating point.
- A byte or `Builder` renderer. `render` returns a `String` that `jsonResponse` encodes through
  `MicroHttp.Utf8`, the path these bodies already take. A byte escaper is candidate 7's concern.

## Proposal

### JSON Value Interface

`Verso.Json` exports the type, lower-case helper constructors, and the renderer:

```haskell
data Json = JNull | JBool Bool | JInt Int | JString String | JArray [Json] | JObject [(String, Json)]

object :: [(String, Json)] -> Json   -- JObject
array  :: [Json] -> Json             -- JArray
string :: String -> Json             -- JString
int    :: Int -> Json                -- JInt
bool   :: Bool -> Json               -- JBool

render :: Json -> String
```

The constructors are exported for pattern matching in the spec; call sites use the helpers
(`Json.object [("deleted", Json.string path)]`). `render` escapes a string to the JSON specification:
`"`, `\`, and the C0 control range U+0000-U+001F, using the short forms `\b \t \n \f \r` where they
exist and `\u00XX` otherwise. It is pure, has no `MicroHttp` dependency, and builds under both
compilers.

### The Response Boundary Renders

`App.jsonResponse` becomes `Json -> Http.Response`, rendering once. The eight body functions in `App`
become `X -> Json`; `View.attachmentsJson` and `View.breadcrumbsJson` (JSON embedded in HTML data
attributes) and `TreeMove`'s three renderers build `Json` too. `View.jsonObject`/`jsonArray`/
`jsonString`/`jsonBool` and `TreeMove.jsonStr` are deleted. The `/operations` endpoint keeps a
raw-body response, because it emits an array of persisted operation-log lines (Non-Goals), and that is
the one JSON response not built from a `Json` value.

### Key Decisions

- `Verso.Json`, not `MicroHttp.Json`. The framework has no JSON and may not import `Verso` (RFC-0030);
  only the wiki emits JSON. YAGNI.
- The handler owns the record-to-`Json` mapping. The JSON keys (`trashId`, `hasChildren`) are the
  API contract, an application concern, so the domain returns typed records and `App` names the keys.
- Correct escaping is a deliberate, correctness-only behaviour change, recorded here and covered by a
  test with a control-character input.

## Alternatives Considered

- Reimplement `View.json*` on top of `Verso.Json` but keep their `[(String, String)]` signatures: the
  leaky interface the review named would survive, so the change would not deliver the candidate.
- A `Json.raw :: String -> Json` escape hatch for the operations endpoint: it admits unescaped bytes
  into the value type, defeating the one-escaper goal. The endpoint keeps its own response instead.

## Security Impact

- Correct control-character escaping closes a path to malformed (and potentially injectable) JSON in an
  API body built from frontmatter titles and tree paths.

## Reliability Impact

- Behaviour-preserving except for the escaping fix, protected by the existing integration `AppSpec`
  (which asserts the JSON bodies of the tree, move, delete, restore, undo, trash and search endpoints)
  and a new `Verso.JsonSpec`.

## Compatibility Impact

- No wire-shape change. A client that today receives an unescaped control character (invalid JSON) now
  receives a valid `\u00XX`; every well-formed value is byte-identical.

## Testing and Quality Gates

- `make check` green before and after.
- New unit spec `test/unit/Verso/JsonSpec.hs`: each variant renders; nesting; the empty object and
  array; every escape including a control character; a property that `render` never emits a raw byte
  below U+0020 inside a string.

## Rollout Plan

Test-first; each phase is committed when green.

### Phase 1: The Module

- [ ] `JsonSpec` covers the render of each variant, nesting, and the full-spec escaping.
- [ ] `Verso.Json` passes it; registered in `test/unit/Main.hs`.

### Phase 2: The Renderers Build Values

- [ ] `App.jsonResponse :: Json -> Http.Response`; the eight `App` body functions return `Json`;
  `View.attachmentsJson`/`breadcrumbsJson` and `TreeMove`'s three renderers return `Json`.
- [ ] `View.jsonObject`/`jsonArray`/`jsonString`/`jsonBool` and `TreeMove.jsonStr` deleted; the
  `/operations` endpoint keeps its raw-body response.

### Phase 3: Records

- [ ] `docs/reviews/` remediation note updated (candidate 6 done); RFC moved to `implemented/`;
  `bun run rfc:index`.

## Open Questions

- None at authoring.
