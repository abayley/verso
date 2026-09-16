---
id: RFC-0044
name: Tree Path Module
status: In Progress
owners:
    - alistair
created: 2026-09-16
updated: 2026-09-16
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0027
    - RFC-0028
    - RFC-0032
---

# Tree Path Module

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-16 |
| Started   | 2026-09-16 |
| Completed |            |

## Summary

Give the document tree's layout one module. `Verso.TreePath` holds a validated, tree-relative path as a
newtype, derives everything the application currently computes by string arithmetic (parent, slug, kind,
section index, meta directory, peer assets, the served filesystem path) and validates trash entry ids.
The route handlers parse a request path once at the edge; `TreeMove`, `DocumentMeta` and `Draft` take a
`TreePath` and become total on paths. The path-safety rule stays in the framework and is exported from
`MicroHttp.Static` so both the static mount and the tree path use one implementation.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 2) found the layout of the document tree spread across five modules as string arithmetic:

- `Static.resolveStaticPath root (pathSegmentsOf p)` appears 17 times in `Verso.App`, 15 in
  `Verso.TreeMove` and twice in `Verso.DocumentMeta`, each site handling its own `Nothing`.
- The parent-directory expression `reverse . drop 1 . dropWhile (/= '/') . reverse` is copied four
  times in `TreeMove` and once more in `Draft`; `TreeMove.parentRel` reimplements
  `DocumentLinks.dirOfPath`; `App`, `DocumentMeta` and `DocumentLinks` each split segments their own way.
- The meta directory convention `<dir>/meta/<base>.meta` is encoded in `DocumentMeta.metaDirectoryFor`
  as a filesystem path and again in `TreeMove.applyPageDelete` as a tree-relative string.
- Trash entry paths are built by `trashRoot ++ "/" ++ id` at six sites; only `deleteTrashEntry` checks
  that the id is all digits.
- Root, page path, section path and trash id are all `String`, so
  `moveSection :: RelevantPages -> FilePath -> String -> String -> String -> Bool -> ...` is told apart
  by argument order.

The review's top recommendation is this change first, because it is pure and mechanical, and because a
structural-operations interface (candidate 1) written over untyped strings would inherit every ambiguity
`TreeMove` has now.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it as complete in the
phase checklist.

## Goals

- One implementation of each layout rule: segment splitting, path safety, parent, slug, kind, section
  index, meta directory, peer assets, served path, trash entry directory.
- Path validity established once per request, at the handler, and carried in the type.
- Trash entry ids validated wherever a path is built from one, not at one site.
- Pure unit tests for the layout rules, needing no filesystem.
- No behaviour change observable over HTTP; the integration suite protects the refactor.

## Non-Goals

- Separate page and section path types. The kind is derived from the last segment and the structural
  operations branch on it at runtime, as they do now.
- Deciding the MicroHs non-ASCII file-name limitation (`docs/reviews/microhs-filepath-encoding-bug-report.md`).
  `TreePath.resolve` is the one place that decision would land; this RFC leaves it a plain `FilePath`.
- Moving the structural transaction (operation log, index, draft, revision) out of the handlers. That is
  candidate 1, a follow-on RFC.
- Changing the on-disk layout or any URL.

## Proposal

### Tree Path Interface

`Verso.TreePath` exports an abstract `TreePath` (`Eq`, `Ord`, `Show`) whose value is a list of validated
segments, the root being the empty list, and:

| Function                                        | Meaning                                                                            |
| ----------------------------------------------- | ---------------------------------------------------------------------------------- |
| `parse :: String -> Maybe TreePath`             | Split on `/`, drop empty segments, accept only if every segment is safe            |
| `root :: TreePath`                              | The document tree itself                                                           |
| `render :: TreePath -> String`                  | Segments joined by `/`; `""` for the root                                          |
| `segments :: TreePath -> [String]`              | The validated segments                                                             |
| `isRoot :: TreePath -> Bool`                    |                                                                                    |
| `kind :: TreePath -> Kind`                      | `Page` when the last segment ends in `.md`, else `Section` (the root is a section) |
| `name :: TreePath -> String`                    | The last segment; `""` for the root                                                |
| `slug :: TreePath -> String`                    | The name without `.md` for a page; the name for a section                          |
| `parent :: TreePath -> TreePath`                | Segments minus the last; the root's parent is the root                             |
| `child :: TreePath -> String -> Maybe TreePath` | One safe segment appended                                                          |
| `sectionIndex :: TreePath -> TreePath`          | The section's `index.md`                                                           |
| `metaDirectory :: TreePath -> TreePath`         | `<parent>/meta/<base>.meta` for a page                                             |
| `peerAssets :: TreePath -> TreePath`            | `<parent>/assets` for a page                                                       |
| `resolve :: FilePath -> TreePath -> FilePath`   | The served filesystem path under a root; total                                     |

and, for the trash:

| Function                                           | Meaning                                  |
| -------------------------------------------------- | ---------------------------------------- |
| `TrashId` (abstract, `Eq`, `Ord`, `Show`)          | An all-digit trash entry name            |
| `parseTrashId :: String -> Maybe TrashId`          | Non-empty and all digits                 |
| `renderTrashId :: TrashId -> String`               |                                          |
| `trashEntryDir :: FilePath -> TrashId -> FilePath` | The entry directory under the trash root |

`parse` canonicalises as `TreeMove` does today (drops empty, doubled and edge slashes) so that string
comparisons in the cycle checks keep working on `render`ed paths. Safety is `MicroHttp.Static.safeComponent`,
newly exported: non-empty, not `.` or `..`, no `/`, `\` or NUL.

### Parse At The Edge

Handlers in `Verso.App` call `TreePath.parse` on the route capture once and answer `404` on `Nothing`,
where they now answer `404` on `resolveStaticPath` returning `Nothing`. `TreeMove.moveSection`,
`movePage`, `deleteTarget` and `restoreFromTrash` take `TreePath` (and `TrashId`) arguments; their
"unsafe path" refusals disappear because the type excludes them. `DocumentMeta.metaDirectoryFor` and
`Draft.draftFsPath` take a `TreePath` and lose their `Maybe`. `TreeMove.replayLog` parses the paths in
each logged operation and skips an operation whose path does not parse, which is already its best-effort
contract for stale operations.

### Key Decisions

- One `TreePath` type, kind derived. Two newtypes would double every structural signature and force the
  handler to classify before calling, for no runtime the code does not already have.
- Parse at the edge. The alternative, parsing inside each module, keeps the `Maybe` at every call and
  leaves the module boundary carrying unvalidated strings.
- Export `Static.safeComponent`. `FileSystem`'s module header already tells callers to validate with it,
  which was impossible while it was private.

## Alternatives Considered

- Leave the strings and add a lint that counts `resolveStaticPath` sites: does not remove the duplicated
  rules or the argument-order ambiguity.
- A `FilePath`-level newtype in the framework: the layout (meta, assets, `index.md`, trash) is the wiki's
  vocabulary, not the framework's (RFC-0030).

## Security Impact

- Path traversal is refused by one rule in one place, and the type proves it was applied.
- Trash entry ids are validated at construction, so every trash path is built from a checked id, where
  today only `deleteTrashEntry` checks.

## Reliability Impact

- Behaviour-preserving refactor protected by the existing unit and integration suites.
- `TreeMove` loses three refusal messages ("unsafe source path", "unsafe destination slug", "unsafe
  destination path"); the handler answers `404` for an unparseable path, as it already does before
  reaching `TreeMove`. The destination slug is validated through `TreePath.child`, refused as before.

## Compatibility Impact

- Internal signatures change in `TreeMove`, `DocumentMeta`, `Draft`; all callers are in this repository.
- No URL, wire format, on-disk layout or configuration change.

## Testing and Quality Gates

- `make check` green before and after.
- New pure unit spec `test/unit/Verso/TreePathSpec.hs`.
- `test/unit/MicroHttp/StaticSpec.hs` covers the exported `safeComponent`.
- Existing `TreeMoveSpec`, `DocumentMetaSpec`, `DraftSpec` and the integration `AppSpec` protect the
  mechanical replacement.

## Rollout Plan

Test-first; each phase is committed when green.

### Phase 1: The Module

- [ ] `Static.safeComponent` exported and unit tested directly.
- [ ] `TreePathSpec`: parse and render round-trip; canonicalisation of `/a//b/`; the root; rejection of
  `.`, `..`, backslash and NUL segments; `kind`; `parent`; `name` and `slug`; `child` and its refusal;
  `sectionIndex`; `metaDirectory`; `peerAssets`; `resolve`; `parseTrashId` and `trashEntryDir`.
- [ ] `Verso.TreePath` passes them. Registered in `test/unit/Main.hs`.

### Phase 2: DocumentMeta And Draft

- [ ] `DocumentMeta.metaDirectoryFor :: FilePath -> TreePath -> FilePath`; its private segment helpers
  deleted; spec updated.
- [ ] `Draft` takes a `TreePath`; its `parentDir` deleted; spec updated.
- [ ] Callers in `App` and `TreeMove` parse at their edge.

### Phase 3: TreeMove

- [ ] `moveSection`, `movePage`, `deleteTarget`, `restoreFromTrash`, `listTrash`, `deleteTrashEntry`,
  `replayLog` take `TreePath` and `TrashId`.
- [ ] `parentRel`, `indexRel`, `joinRel`, `dropDotMd`, `slugOfPath`, the four `parentDir` copies, and the
  `resolveStaticPath`/`trashRoot ++` sites replaced.
- [ ] `TreeMoveSpec` updated; the removed "unsafe" refusal cases become `parse` cases in `TreePathSpec`.

### Phase 4: App

- [ ] Every handler parses its capture once; the 17 `resolveStaticPath` sites, `pathSegments`,
  `parentOfRel`, `isMarkdownPath`, `joinRel`, `slugForPath`, `lastSegment`, `splitOn` and the duplicate
  trimmers replaced or deleted.
- [ ] `assetsDirectoryFor` becomes `TreePath.peerAssets`.

### Phase 5: Records

- [ ] `CONTEXT.md` gains "Tree path" and "Trash entry id".
- [ ] `docs/architecture/` note where the layout lives; RFC moved to `implemented/`; `bun run rfc:index`.

## Open Questions

- None at authoring. Anything the phases meet that this RFC does not cover is added here before the
  affected scope changes.
