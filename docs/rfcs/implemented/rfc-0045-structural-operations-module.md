---
id: RFC-0045
name: Structural Operations Module
status: Implemented
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
    - RFC-0044
---

# Structural Operations Module

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-16 |
| Started   | 2026-09-16 |
| Completed | 2026-09-16 |

## Summary

Give the document tree's structural operations one module. `Verso.Structure` owns the transaction a
create, move, delete, restore or undo performs: apply the filesystem change through `Verso.TreeMove`,
append the operation log record, maintain the derived indexes, carry the page's draft, and record a
revision, all under the write lock. Its interface is the five operations, each returning an outcome
value or a refusal. The route handlers shrink to parse the request, call the operation and render the
outcome, and the transaction can be tested without an HTTP request.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 1) found that the structural operations have no module. `Verso.TreeMove` performs the
filesystem half; the transaction half lives in four request handlers and the undo core in `Verso.App`:

- The ordering "apply, append to the operation log, maintain the index, relocate the draft, commit"
  is written out in `treeMoveHandler`, `treeDeleteHandler`, `treeRestoreHandler` and `applyInverse`.
- The operation log record is built by hand in five places.
- `applyInverse`, the undo core, returns `IO (Either String String)` where the `String` is an already
  rendered JSON body, so even the extracted core is response-shaped.
- `createTreeNode` returns an `Http.Response` inside its result.
- Every one of these paths is reachable from a test only by constructing raw HTTP request bytes and a
  temp tree; the integration `AppSpec` is 1,155 lines organised by RFC for that reason.

RFC-0044 made the paths these operations take typed and total, which is the precondition for an
interface written over them.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it as complete in the
phase checklist.

## Goals

- One implementation of the structural transaction and of the operation log record.
- Operations return data (an outcome or a refusal); rendering to JSON and status codes stays in the
  handler.
- The transaction's collaborators (page source, index maintenance, operation store, trash store,
  versioning, the revision commit) are fields of one record the handler is given, so a test supplies
  recording adapters and asserts ordering through them.
- Undo reuses move, restore and delete rather than copying them.
- No behaviour change observable over HTTP.

## Non-Goals

- Typed maintenance events (candidate 8). The maintenance hooks keep their shape; only their home
  moves.
- A JSON value type (candidate 6). Handlers keep rendering with `View.json*`.
- Moving the trash's filesystem mechanics out of `TreeMove` (candidate 3).
- The pure preview/apply plan for a move (a `TreeMove` concern).

## Proposal

### Structural Operations Interface

`Verso.Structure` exports a collaborator record and five operations:

| Name | Meaning |
| --- | --- |
| `Structure` | root, trash root, write lock, page source, maintenance, operation store, trash store, versioning, revision commit |
| `create :: Structure -> TreePath -> Kind -> String -> IO (Either Refusal Created)` | a page or section under a parent, from a title |
| `move :: Structure -> Identity -> TreePath -> TreePath -> String -> Bool -> IO (Either Refusal MovePlan)` | source, destination parent, slug, confirm |
| `delete :: Structure -> Identity -> TreePath -> IO (Either Refusal Deleted)` | to the trash; `Deleted` carries the path, kind and trash id |
| `restore :: Structure -> Identity -> TrashId -> IO (Either Refusal Restored)` | from the trash; `Restored` carries the path and kind |
| `undo :: Structure -> Identity -> Maybe Int -> IO (Either Refusal Undone)` | the inverse of one operation (by seq) or the latest |
| `purge :: Structure -> String -> IO Bool` | permanently removes a trash entry by raw id, forgetting it in the catalogue |
| `Refusal = Refused String \| StillReferenced [(page, link)]` | a refusal the handler answers `409` (or `400` for create) with |

The write lock, `IndexMaintenance` (with its no-op and combinator), `Versioning` and the draft
relocation helpers move from `App` into `Structure`. `App` keeps the adapters that build a maintenance
record from a link-index store and a search runtime, and re-exports `Versioning` and `noVersioning`
for the tests that name them.

### Key Decisions

- The revision commit is a field, `Git.Identity -> String -> IO ()`. In production it is
  `commitStructural` (a no-op when versioning is off); a test supplies a recording function, so the
  ordering "append then commit" is asserted without a git repository.
- Outcomes are records of typed paths and ids; the handler renders. Undo's outcome is a sum over the
  three inverses so the handler can render each as it does today.
- Create returns a `Refused` for a missing title or unknown kind; the handler maps a create refusal to
  `400` and every other refusal to `409`, as now.

## Alternatives Considered

- A typeclass or record of operations with two adapters (real, fake): the fake would be a second
  implementation of the transaction, which is what the tests are meant to check. Recording adapters
  behind the existing collaborator seams give the same testability with one implementation.
- Folding the transaction into `TreeMove`: it would make the filesystem module depend on the operation
  store, trash catalogue, drafts and git, inverting its current leaf position and widening its
  interface.

## Security Impact

- None beyond RFC-0044: every path and trash id the operations take is already validated.

## Reliability Impact

- Behaviour-preserving refactor protected by the integration `AppSpec` and a new `StructureSpec` that
  asserts the transaction's effects and their order through recording adapters; delete and restore
  commit before they append, as the handlers did, and move appends before it commits.
- Differences from the handlers as they were, found in the code review of 2026-09-16 and kept:
  undo now carries a page's draft, because the inverse of a delete is the restore transaction and
  the inverse of a restore is the delete transaction (the old inverse moved no draft); undoing a
  restore that is refused because the target is referenced answers with the referrers JSON rather
  than a text reason; the undo refusal for a delete record without a trash id says "no valid trash
  id"; the navigation tree hides a directory entry whose name is not a safe path segment; a create
  checks the parent path and the kind before the title. Emptying the trash and the retention sweep
  run under one hold of the write lock through `purgeMatching`, as before. `Verso.App` shrank from
  2,290 to about 1,860 lines.

## Compatibility Impact

- Internal signatures change in `App`; nothing external.

## Testing and Quality Gates

- `make check` green before and after.
- New `test/integration/Verso/StructureSpec.hs` (filesystem I/O, so the integration tier), asserting
  through the operation store, a recording maintenance record and a recording commit.

## Rollout Plan

Test-first; each phase is committed when green.

### Phase 1: The Module Beside The Handlers

- [x] `StructureSpec`: an applied move logs one record and notifies maintenance and the commit, in
  that order; a preview logs nothing; a refused move logs nothing; a delete trashes, logs, records the
  catalogue entry and notifies; a referenced delete is `StillReferenced`; a restore logs, forgets the
  catalogue entry and notifies; undo of nothing is refused; undo of a move reverses it and logs the
  inverse; a create writes the seeded page and notifies; with versioning on a move carries the draft.
- [x] `Verso.Structure` passes them, built from the code moved out of `App`.

### Phase 2: The Handlers Call It

- [x] `treeMoveHandler`, `treeDeleteHandler`, `treeRestoreHandler`, `treeUndoHandler`,
  `treeCreateHandler`, the trash purge handlers and the retention sweep call `Structure`; the moved
  code is deleted from `App`.
- [x] `App` re-exports `Versioning` and `noVersioning`; the route table builds one `Structure`.

### Phase 3: Records

- [x] Architecture note updated; RFC moved to `implemented/`; `bun run rfc:index`.

## Open Questions

- None at authoring.
