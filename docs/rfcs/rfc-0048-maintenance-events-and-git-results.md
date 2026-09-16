---
id: RFC-0048
name: Maintenance Events And Git Results
status: In Progress
owners:
    - alistair
created: 2026-09-16
updated: 2026-09-16
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0029
    - RFC-0032
    - RFC-0034
    - RFC-0045
---

# Maintenance Events And Git Results

| Stage     | Timestamp  |
| --------- | ---------- |
| Authored  | 2026-09-16 |
| Started   | 2026-09-16 |
| Completed |            |

## Summary

Two seam cleanups the architecture review named as candidate 8. First, replace the five-closure
`IndexMaintenance` record with one typed handler over a `Verso.Maintenance.Event` sum, so a structural
operation notifies the derived indexes by emitting a value and a new event kind is one constructor
rather than a new field in every adapter. Second, stop the git layer discarding the results of the
operations that set up and commit the repository, so a failed `git init` or a failed staging is
surfaced rather than reported as success.

## Context

The architecture review of 2026-09-16 (`docs/reviews/architecture-review-haskell-20260916.html`,
candidate 8) found two seams that exist but leak:

- The index-maintenance seam is a record of five `String -> IO ()` closures
  (`onMove`/`onDelete`/`onCreate`/`onRestore`/`onSave`, in `Verso.Structure` since RFC-0045), combined
  from two adapters (the link index and search). It is a real seam, but a repeated-switch shape: every
  adapter, the no-op and the combinator spell out all five hooks, and adding a sixth touches each.
- The git layer discards results. `ensureRepository` throws away the results of `git init`,
  `git add -A` and the import commit, so a failed init still returns `Initialised` and the server runs
  on a repository that does not exist, with every later publish failing silently. `commitPaths`
  ignores each `git add` result, so a staging failure is not seen before the commit.

RFC-0045 gave the maintenance hooks a single caller (`Verso.Structure`), which the review noted is the
precondition for turning them into events.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it as complete in the
phase checklist.

## Goals

- One maintenance handler over a typed event, in its own module; a new event kind is one constructor
  and one case arm per adapter.
- `ensureRepository` surfaces a setup failure as a value the caller logs; a failed `git init` is no
  longer reported as an initialised repository.
- `commitPaths` surfaces a staging failure as `CommitFailed` rather than committing past it.
- No behaviour change on the success paths; the recorded maintenance order and the JSON responses are
  unchanged.

## Non-Goals

- `logForPath`. Its one caller renders the same empty-state history page whether the command failed or
  the page has no history, so changing its type would be churn with no consumer. It stays as it is.
- Making a failed publish commit a request error. The content is already saved to disk; a publish still
  answers `204`, but a failed commit is now logged rather than silently dropped, as `commitRevision`
  already logs a failed structural commit.
- The search or link-index adapters' own behaviour; only their shape as a handler changes.

## Proposal

### Verso.Maintenance

A small module owns the seam:

```haskell
data Event
    = Moved String String   -- from, to (rendered tree paths)
    | Deleted String
    | Created String
    | Restored String
    | Saved String

type Maintenance = Event -> IO ()

none :: Maintenance                       -- \_ -> pure ()
combine :: Maintenance -> Maintenance -> Maintenance   -- \e -> a e >> b e
```

`Verso.Structure`'s `structureMaintenance` becomes a `Maintenance.Maintenance`; the transaction emits
`Maintenance.Moved (render from) (render to)`, `Maintenance.Deleted path` and so on where it calls the
named hooks today. `Verso.App`'s `storeMaintenance` and `searchMaintenance` become one function each,
a `case` over the event; `maint` is `Maintenance.combine`. The `IndexMaintenance` record, its no-op and
its combinator leave `Structure`. The content handlers that notify a save
(`treeSave`/`treePutDocument`/`treeRollback`) emit `Maintenance.Saved path`.

### Git Results

- `ensureRepository :: FilePath -> Identity -> IO (Either String RepoInit)`. An existing repository is
  `Right AlreadyPresent`. Otherwise `git init` runs and its exit is checked: a non-zero exit is
  `Left` with the captured stderr; success proceeds to `git add -A` and the import commit and returns
  `Right Initialised`. `appFromConfig` logs the `Left` as a degraded-versioning warning, beside the
  existing "git not found" one.
- `commitPaths` checks each `git add`; if any staging fails it returns `CommitFailed` with the stderr
  instead of committing. The happy path (the paths exist, as at every real call site) is unchanged.
- `treePutDocument` logs a `CommitFailed` from the publish commit to stderr, matching
  `Structure.commitRevision`.

This establishes the contract recorded in ADR-0093: a fallible git operation returns a typed result and
its caller logs or acts on a failure; none is discarded.

### Key Decisions

- `Verso.Maintenance` is its own module, not more constructors inside `Structure`, so the event
  constructors (`Deleted`, `Created`, `Restored`) do not collide with `Structure`'s outcome types of
  the same names, and the seam has a home the review's diagram named.
- The event carries the rendered `String` path, matching the index and search consumers, which are
  `String`-based; the transaction renders its `TreePath` at the point of emission, as it does now.
- `ensureRepository` returns `Either String RepoInit` (ADR-0009's house style for a fallible
  operation) rather than a new `RepoInit` failure constructor, so the caller's `Right` cases stay the
  two it already handles.

## Alternatives Considered

- Keep the record and add a sixth hook when needed: the repeated-switch stays, and every adapter, the
  no-op and the combinator keep listing all hooks.
- A `RepoInit = Initialised | AlreadyPresent | InitFailed String`: mixes success and failure in one
  type where the codebase's convention is `Either` for a fallible operation.

## Security Impact

- None.

## Reliability Impact

- A failed repository setup is now visible in the startup log instead of masquerading as success, so a
  broken versioning configuration is diagnosable rather than silent.
- The maintenance change is behaviour-preserving, protected by the integration `StructureSpec` (which
  records the events in order) and `AppSpec`.

## Compatibility Impact

- `ensureRepository`'s type changes; its only caller is `appFromConfig`. No wire, on-disk or
  configuration change.

## Testing and Quality Gates

- `make check` green before and after.
- `test/integration/Verso/GitSpec.hs` gains: `ensureRepository` on a fresh directory is
  `Right Initialised` and on a second call `Right AlreadyPresent`; `ensureRepository` on a path that is
  a regular file is a `Left`; `commitPaths` with a path that does not exist is `CommitFailed`.
- `StructureSpec` is updated to the handler shape and keeps asserting the same recorded event order.

## Rollout Plan

Test-first; committed when green.

### Phase 1: Maintenance Events

- [ ] `Verso.Maintenance` with `Event`, `Maintenance`, `none`, `combine`.
- [ ] `Structure` emits events; `App`'s two adapters and the content handlers use the handler;
  `IndexMaintenance` and its combinators leave `Structure`.
- [ ] `StructureSpec`'s recording adapter is a handler; the recorded-order assertions are unchanged.

### Phase 2: Git Results

- [ ] `GitSpec` gains the `ensureRepository` success, already-present and failure cases and the
  `commitPaths` staging-failure case.
- [ ] `ensureRepository` returns `Either String RepoInit`; `commitPaths` surfaces a staging failure;
  `appFromConfig` and `treePutDocument` handle the results. ADR-0093 recorded.

### Phase 3: Records

- [ ] Architecture page and `CONTEXT.md` (if it names the seam) updated; RFC moved to `implemented/`;
  `bun run rfc:index`, `bun run adr:index`.

## Open Questions

- None at authoring.
