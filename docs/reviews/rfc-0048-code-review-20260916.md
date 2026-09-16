# RFC-0048 code review: maintenance events and git results

Status: review (2026-09-16). Change set: `cbfdb62..9bfb69c` on `main`, three commits. About 130
insertions and 90 deletions across six source and test files: the new `Verso.Maintenance` module and
the rewiring of `Verso.Structure` and `Verso.App` onto it (RFC-0048 half A); `Verso.Git`'s
`ensureRepository` and `commitPaths` surfacing failures with startup and publish logging in
`Verso.App` (half B, ADR-0093); the new `GitSpec` cases and the `StructureSpec` recorder change; and
the architecture page and the RFC and ADR records.

The review ran along the two usual independent axes, each in its own sub-agent: Spec (does the code do
what RFC-0048 and ADR-0093 say, and are the documents accurate) and Standards (documented conventions
and the Fowler smell baseline). A third sub-agent desk-traced and probed correctness against a real git
repository, with particular attention to whether `commitPaths`'s new staging check could turn a valid
rename commit into a failure. The sections are not reranked against each other. Each finding is
labelled MEASURED (a command or git probe was run), VERIFIED (traced end to end) or INFERRED.

Baseline for the review, all MEASURED at `9bfb69c`: `make check` passes in full (mhs unit 612, mhs
integration 160, the same under GHC, the editor checks, both smokes, the chrome gates).

## RFC-0048 Correctness Findings

No correctness defects. The one risk the change raised is disproven by measurement.

### Correctness 1: the staging check does not break a rename or a deletion commit

MEASURED (git probe in a real repository), VERIFIED against the rename test.

`commitPaths` now returns `CommitFailed` if any `git add` exits non-zero. The concern was that
committing a rename passes the old, now-deleted path (`["a.md", "b.md"]`), and that `git add -- a.md`
for a deleted file might fail. The probe confirms `git add` of a deleted tracked path exits 0 (it
stages the deletion) and of a new file exits 0; only a path that never existed exits non-zero. So the
rename test ([GitSpec.hs:139](../../test/integration/Verso/GitSpec.hs#L139)) stages both paths, reaches
`commitStaged`, and commits, as before. The `make check` rename test passing is the end-to-end
confirmation.

### Correctness 2: the maintenance seam is behaviour-identical

MEASURED (comparison against `git show cbfdb62`), VERIFIED at every site.

`Maintenance.combine a b event = a event >> b event` with `a = storeMaintenance`, `b =
searchMaintenance` preserves the old link-then-search order. Each event arm is byte-identical to its
old record field, including the `Deleted` arm's subtree removal then parent `applyChanges`, the
`Restored` arm's subtree add then parent `applyChanges`, and the unchanged `parentIndexPath`. Structure
emits an event at every former hook site with the same rendered-string arguments, including the undo
inverse's `Moved to from` order. The content-save handlers keep their guards: `treeSave` emits `Saved`
only when versioning is off, `treePutDocument` and `treeRollback` unconditionally.

### Correctness 3: the git happy paths are unchanged and the failure paths are surfaced

MEASURED (git probes), VERIFIED at the call sites.

`ensureRepository` runs the same commands in the same order on a present or freshly-initialised repo,
wrapping the result in `Right`; on a `git init` failure it short-circuits before `add`/`commit` (which
the old code ran against a non-repo) and returns `Left`. `appFromConfig` handles all three cases;
`reportPublishCommit` logs only `CommitFailed`. Both new `GitSpec` negative cases were reproduced by
probe (a regular-file root makes `git init` exit 128; a nonexistent path makes `git add` exit 128).

### Correctness 4: two pre-existing behaviours noted, not regressions

INFERRED. `ensureRepository` still trusts a present `.git` without validating it, unchanged and out of
scope. `commitPaths` is non-atomic on a partial add failure (earlier adds stay staged), but its only
production caller passes a single existing path, and structural operations and rollback use `commitAll`
(`git add -A`); no action needed.

## RFC-0048 Spec Findings

No findings. The `Verso.Maintenance` interface matches the RFC's proposed block; every adapter arm maps
field-for-field to the old record with the same behaviour; `logForPath` is unchanged, honouring the RFC
non-goal and ADR-0093's stated exception; `ensureRepository` and `commitPaths` behave as the RFC and
ADR describe; and the promised `GitSpec` and `StructureSpec` cases exist and assert what is claimed. The
architecture page, RFC index and ADR index match the code.

## RFC-0048 Standards Findings

No hard violations. `Verso.Maintenance` has a module header and per-function Haddock; the removal of
`IndexMaintenance`, `noIndexMaintenance` and `combineMaintenance` from `Structure` left no dangling
reference; the git changes follow ADR-0009's Either/typed-result convention; the eta-expanded
maintenance builders match the codebase, which uses no `LambdaCase`.

### Standards 1: the stderr-capture idiom is repeated in Git

VERIFIED. `Utf8.decodeBytes (Process.procErr ...)` now appears three times in `Verso.Git`
(`ensureRepository`, `commitPaths`, and the pre-existing `commitStaged`). A one-line helper removes the
repeat. Minor.

### Standards 2: the event carries String, and two adapters switch on it

Judgement calls, both documented and intended. `Event`'s five `String` payloads are primitive relative
to `TreePath`, but the module header states the consumers are string-based and the emitter renders at
the point of emission. The two `App` adapters each `case` over the five constructors, a repeated switch,
but that is the shape the RFC chose over the record of closures at two adapters; a third adapter would
be the point to reconsider. Left as they are.

## Summary

Correctness: four sections, no defects, the rename risk disproven by measurement. Spec: no findings.
Standards: no violations; one small duplication worth removing, the rest documented and intended.

## Remediation Summary

Applied on 2026-09-16. The one actionable finding was addressed; every gate below was rerun.

### Remediation of the standards finding

- Standards 1 (fixed): a private `decodedErr :: Process.ProcResult -> String` in `Verso.Git` replaces
  the three copies of `Utf8.decodeBytes (Process.procErr ...)` in `ensureRepository`, `commitPaths`
  and `commitStaged`. Behaviour-preserving, covered by the existing `GitSpec`.

### Findings left as they are

- Standards 2 (the event's `String` payloads and the two-adapter switch) are documented, intended
  choices, kept.
- Correctness 4 (a present `.git` trusted without validation; `commitPaths` non-atomic on a partial
  add failure) are pre-existing and out of scope, with no production caller reaching the second.

### Verification after remediation

MEASURED: `make format`, `make lint`, the mhs unit suite (612 examples) and integration suite (160),
the same under GHC.
