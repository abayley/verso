---
id: RFC-0047
name: Trash Owns Its Mechanics
status: In Progress
owners:
    - alistair
created: 2026-09-16
updated: 2026-09-16
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0028
    - RFC-0045
---

# Trash Owns Its Mechanics

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-16 |
| Started   | 2026-09-16 |
| Completed |            |

## Summary

Move the trash's filesystem mechanics into `Verso.Trash`, so one module owns a trash entry: its
provenance manifest and the operations that store items into an entry, restore them, list entries and
purge one. `Verso.TreeMove` keeps only the document-tree parts of delete and restore (the referrer
check, the asset classification, the listing update) and calls `Verso.Trash` for the entry mechanics.
The dependency that ran the wrong way, `Verso.TrashStore` importing `Verso.TreeMove` to list entries,
is replaced by `TrashStore` importing `Trash`.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 3) found the trash spread across modules with a dependency running the wrong way. RFC-0045
already moved the retention policy out of the route module into `Structure.purgeMatching`. What
remains is:

- The trash entry mechanics live in `Verso.TreeMove`: `moveIntoTrash`, `moveDirIntoTrash`,
  `restoreItem`, `targetOccupied`, `listTrash`, `deleteTrashEntry` and its `removeTree`, plus a
  pointless `writeManifest` that just re-exports `Trash.writeManifest`.
- `Verso.TrashStore` (the warm catalogue) imports `Verso.TreeMove` only for `listTrash`
  (`TrashStore.hs:56`), so the catalogue depends on the 800-line move engine to read itself.
- `Verso.Structure.purgeEntry` reaches `TreeMove.deleteTrashEntry`.

So `Verso.Trash` owns the manifest but not the files the manifest describes, and the two are split
across `Trash` and `TreeMove`.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it as complete in the
phase checklist.

## Goals

- `Verso.Trash` owns a trash entry end to end: its manifest and its filesystem mechanics.
- `Verso.TrashStore` and `Verso.Structure` depend on `Verso.Trash` for trash operations, not on
  `Verso.TreeMove`.
- The `TrashStore -> TreeMove` dependency is gone.
- No behaviour change; the existing suites plus a new `Verso.Trash` seam test protect the move.

## Non-Goals

- Merging the warm catalogue (`Verso.TrashStore`) or the retention sweep (`Structure.purgeMatching`,
  RFC-0045) into `Verso.Trash`. The catalogue is a warm cache over the durable entries with its own
  MVar and operation-log join; keeping it a separate adapter over `Trash` is the honest cut. Its
  dependency simply turns from `TreeMove` to `Trash`.
- The document-tree parts of delete and restore. The referrer check (`DocumentLinks.referrersMatching`),
  the asset classification (`classifyMovingAssets`) and the listing edits
  (`removeParentListing`/`reAddListing`) are about the tree, not the trash, and stay in `TreeMove`.
  `deleteTarget` and `restoreFromTrash` stay there and orchestrate both.
- Any change to the manifest format or the on-disk trash layout.

## Proposal

### Verso.Trash Interface

`Verso.Trash` keeps the manifest type and functions (`TrashItem`, `Manifest`, `renderManifest`,
`parseManifest`, `readManifest`, `writeManifest`) and gains the entry mechanics, moved verbatim from
`TreeMove`:

| Function                                                                                  | Meaning                                                  |
| ----------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `moveIntoTrash :: Root -> EntryDir -> String -> TreePath -> Bool -> IO (Maybe TrashItem)` | Move one tree path into an entry under a stored name     |
| `moveDirIntoTrash :: Root -> EntryDir -> String -> TreePath -> IO (Maybe TrashItem)`      | As above for a directory that may be absent              |
| `restoreItem :: Root -> EntryDir -> TrashItem -> IO ()`                                   | Move one stored item back to its origin                  |
| `targetOccupied :: Root -> TreePath -> String -> IO Bool`                                 | Whether a restore target is now occupied                 |
| `listTrash :: TrashRoot -> IO [(String, String, String)]`                                 | The entries as `(id, path, kind)`, reading each manifest |
| `deleteTrashEntry :: TrashRoot -> TrashId -> IO Bool`                                     | Permanently remove one entry directory                   |

`Verso.Trash` gains imports of `MicroHttp.FileSystem` and `Verso.TreePath` (both leaf modules; no
cycle, since neither imports `Trash`). The entry-directory path is `TreePath.trashEntryDir`, as now.

### The Callers

- `TreeMove.applyPageDelete`/`applySectionDelete`/`restoreFromTrash` call `Trash.moveIntoTrash`,
  `Trash.moveDirIntoTrash`, `Trash.restoreItem`, `Trash.targetOccupied` and `Trash.writeManifest`
  where they call the local helpers today. The tree helpers they keep (`removeParentListing`,
  `reAddListing`, `classifyMovingAssets`) are unchanged.
- `TreeMove` drops `listTrash` and `deleteTrashEntry` (and the local `writeManifest` re-export) from
  its exports and body; `deleteTarget` and `restoreFromTrash` stay.
- `TrashStore.loadTrashEntries` calls `Trash.listTrash`. `TrashStore` no longer imports `TreeMove`.
- `Structure.purgeEntry` calls `Trash.deleteTrashEntry`.

### Key Decisions

- The mechanics are a `Trash` concern, not a `TreeMove` one. `TreeMove` is the move engine; storing a
  file in an entry and reading it back is the trash's own business, and the manifest already lives
  there.
- The warm catalogue stays separate (Non-Goals). Merging it would pull an MVar and the operation-log
  timestamp join into the durable-mechanics module for no gain.

## Alternatives Considered

- A higher-level `Trash.storeEntry`/`restoreEntry` that also owns the manifest assembly: it would have
  to take the removed-listing line and the asset set, which are tree concerns computed in `TreeMove`,
  so the seam would carry tree data across it. Moving the granular mechanics keeps each side's data on
  its own side.
- Leaving `listTrash` in `TreeMove` and having `TrashStore` import a smaller module: there is no
  smaller module; the honest fix is to move the function to where the concept lives.

## Security Impact

- None. The digits-only trash-id guard is already in `TreePath.parseTrashId` (RFC-0044); this moves
  code between modules without changing what it validates.

## Reliability Impact

- Behaviour-preserving move, protected by the integration `AppSpec` and `TreeMoveSpec` (delete,
  restore and purge end to end), `TrashStoreSpec` (the catalogue over `listTrash`), and a new
  `Verso.Trash` seam test that stores an item into an entry, lists it, restores it and purges it
  through the `Trash` interface directly.

## Compatibility Impact

- Internal module boundaries only. No wire, on-disk or configuration change.

## Testing and Quality Gates

- `make check` green before and after.
- New `test/integration/Verso/TrashSpec.hs` (filesystem I/O, integration tier) exercising the moved
  mechanics through `Verso.Trash`.

## Rollout Plan

Test-first; committed when green.

### Phase 1: Move The Mechanics

- [ ] `test/integration/Verso/TrashSpec.hs`: a store-list-restore-purge round trip through the target
  `Verso.Trash` interface (RED until the functions move).
- [ ] The six functions and `removeTree` move from `TreeMove` to `Verso.Trash`, which gains its
  `FileSystem`/`TreePath` imports; `TreeMove` calls `Trash.*` and drops the two exports and the
  `writeManifest` re-export.
- [ ] `TrashStore` and `Structure` call `Trash.listTrash`/`Trash.deleteTrashEntry`; `TrashStore` drops
  its `TreeMove` import.

### Phase 2: Records

- [ ] `CONTEXT.md` Trash entry note points at `Verso.Trash`; architecture page updated; RFC moved to
  `implemented/`; `bun run rfc:index`.

## Open Questions

- None at authoring.
