---
id: RFC-0031
name: Haskell style cleanups -- qualified imports, Haddock, Http inlining
status: Draft
owners:
    - alistair
created: 2026-06-28
updated: 2026-06-28
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Haskell style cleanups -- qualified imports, Haddock, Http inlining

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-28       |
| Started   | 2026-06-28       |
| Completed |                  |

## Summary

Three Haskell-wide style cleanups: (1) every top-level function in `src/` gets a
Haddock comment; (2) every import is qualified with a short alias so a name's
origin is lexically obvious (local vs imported), in both `src/` and `test/`, with
the Prelude and the Hspec test DSL as the two explicit exceptions; (3) the small
`MicroHttp.Http.*` submodules are inlined into `MicroHttp.Http`, except
`MicroHttp.Http.Parse`, which must stay as an internal module to avoid a
`Http` <-> `Stream` import cycle.

## Context

The codebase uses many unqualified imports, so at a use-site it is not obvious
whether a name is local or imported -- the maintainer's stated preference is to
tell this lexically. ~234 of 638 top-level signatures in `src/` lack Haddock. The
`MicroHttp.Http` namespace has five small submodules (463 lines across Framing,
Parse, Parser, PercentEncoding, Response) that add navigation overhead.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it
complete in the phase checklist. Run `make format` then `make check` (green)
before each commit. Commit per phase/group.

## Goals

- Every top-level function/value in `src/` has a Haddock comment.
- Every import in `src/` and `test/` is qualified with an alias, except the
  Prelude (unavoidable) and `Test.Hspec` (a DSL; qualification would be very
  verbose).
- `MicroHttp.Http` is the single HTTP interface module; `Framing`, `Parser`,
  `PercentEncoding`, `Response` are inlined into it.
- `make check` green at every commit; no behaviour change.

## Non-Goals

- No behaviour, API surface, or wire change (purely lexical/structural).
- No Haddock on test functions, or on local `where`/`let` helpers.
- No qualification of the Prelude or the `Test.Hspec` DSL.
- No new functionality.

## Proposal

### Decisions

- **Prelude stays unqualified.** `map`, `show`, `Maybe`, `Either`, `IO`, `$`,
  `<>`, etc. cannot practically be qualified; these remain the one class of
  imported-but-unqualified names.
- **`Test.Hspec` stays unqualified** in test modules (a DSL: `describe`, `it`,
  `shouldBe`, `expect`, ...). All *other* test imports (the modules under test,
  stdlib) are qualified.
- **`MicroHttp.Http.Parse` stays a separate module.** `MicroHttp.Http` uses
  `StreamError` (from `MicroHttp.Stream`) in `Application`/`ResponseBody`, and
  `MicroHttp.Stream`'s `StreamError` wraps `ParseError` (from `Http.Parse`).
  Merging `Parse` into `Http` would make `Http` <-> `Stream` mutually recursive,
  which mhs cannot compile. `MicroHttp.Http` re-exports `ParseError`,
  `ParseLimits`, `defaultParseLimits` from `Http.Parse`, so external callers still
  import only `MicroHttp.Http`; `Stream` keeps importing the internal `Http.Parse`.

### Alias convention

Local last segment for project modules; standard short aliases for stdlib. Where
two modules share a last segment, the framework one keeps the short alias and the
application one is distinguished.

| Module | Alias |
|---|---|
| `Data.ByteString.Char8` | `BS` (sole) / `BSC` (when `Data.ByteString` also imported) |
| `Data.ByteString` | `BS` (sole) / `B` (alongside Char8) |
| `Data.Map` / `.Strict` | `Map` |
| `Data.Char` | `Char` |
| `Data.List` | `List` |
| `Data.Maybe` | `Maybe` |
| `Data.Word` | `Word` |
| `Control.Monad` | `Monad` |
| `Control.Concurrent.MVar` | `MVar` |
| `System.Directory` | `Directory` |
| `System.Environment` | `Environment` |
| `System.Exit` | `Exit` |
| `System.IO` / `System.IO.*` | `IO` / last segment (`Base`, `Open`, `TimeMilli`) |
| `Foreign.Ptr` / `.Storable` / `.Marshal.Alloc` | `Ptr` / `Storable` / `Alloc` |
| `Foreign.C.String` / `.Types` | `CStr` / `CTypes` |
| `MicroHttp.*`, `Verso.*` | last segment (`Http`, `Stream`, `Router`, `LinkIndex`, ...) |
| `MicroHttp.Config` vs `Verso.Config` | `Config` vs `VConfig` |

### Haddock

Every top-level binding with a signature gets a `-- |` (or `{- | -}`) comment
stating what it is/does, in the existing literate house style. Functions that are
self-evident still get a one-line comment.

## Alternatives Considered

- Fully inline `Http.Parse` too: rejected -- creates a `Http` <-> `Stream` cycle.
  Alternative cycle-breaks (relocating `StreamError`, merging `Stream` into
  `Http`) are larger and out of scope.
- Qualify the Hspec DSL: rejected by decision -- ~2000 call-sites, very verbose.
- Leave tests unqualified entirely: rejected by decision -- qualify test module
  imports too (Hspec excepted).

## Security Impact

- None. Purely lexical/structural.

## Reliability Impact

- No runtime change. Risk is mechanical (a mis-qualified name, a missed
  re-export); mitigated by `make check` green per group and small commits.

## Compatibility Impact

- Internal only: `MicroHttp.Http.{Framing,Parser,PercentEncoding,Response}` cease
  to exist as separate modules (their contents and exports move to
  `MicroHttp.Http`). `MicroHttp.hs` umbrella and external imports adjust to
  `MicroHttp.Http`. No external/wire change.

## Testing and Quality Gates

- `make check` (markdownlint, fourmolu, hlint, mhs unit+integration, editor-check)
  green before every commit. No new tests (no behaviour change); existing specs
  must pass after each transformation.

## Rollout Plan

Each phase/group is one commit, `make format` + `make check` green first.

1. **[DONE] Phase 1 -- Inline Http submodules.** Merged `Framing`, `Parser`,
   `PercentEncoding`, `Response` into `MicroHttp.Http`; re-exported `Parse` types;
   deleted the four files (`Http.Parse` kept). Per-area spec files retained,
   re-pointed at `MicroHttp.Http`. Updated importers (Middleware, Router, Server,
   Settings, Verso.App) and the `MicroHttp.hs` umbrella. Unified BS alias
   (`BS`=Data.ByteString, `BSC`=Char8) in the merged module.
2. **Phase 2 -- Qualify + Haddock, framework core.** `MicroHttp.{Iteratee,
   Stream, Network.Socket, Http, Http.Parse, Server, Settings, Config, Router,
   Static, Middleware, Log, Html, FileSystem}` and `MicroHttp.hs`: qualify all
   imports, add Haddock to every top-level binding. Commit in sensible sub-groups.
3. **Phase 3 -- Qualify + Haddock, Verso app.** All `Verso.*` modules + the
   executables (`Main`, `ReplayTool`).
4. **Phase 4 -- Qualify tests.** Qualify module/stdlib imports across `test/`
   (`Test.Hspec` stays unqualified). No Haddock added to tests.
5. **Phase 5 -- Docs + memory.** ADR for the Http inlining + the qualified-import
   convention; update memory. Mark RFC Implemented.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC does not cover, stop changing
  the affected scope before inventing a contract, add the smallest missing
  decision to `## Open Questions`, include evidence/impact/options, and continue
  only after approval.

## Open Questions

- None.
