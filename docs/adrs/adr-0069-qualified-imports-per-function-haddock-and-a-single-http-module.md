---
id: ADR-0069
name: Qualified Imports, Per-Function Haddock, and a Single Http Module
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0031]
---

# ADR-0069: Qualified Imports, Per-Function Haddock, and a Single Http Module

> Status: Accepted (RFC-0031).

## Context

unqualified imports made it hard to tell at a use-site whether a name is
local or imported; ~37% of top-level functions lacked Haddock; and the
`MicroHttp.Http` namespace had five small submodules that added navigation
overhead.

## Decision

- **Qualify every import with a short alias** in both `src/` and `test/`, so a
  name's origin is lexically obvious. Two exceptions: the Prelude (cannot be
  practically qualified) and `Test.Hspec` (a test DSL; qualifying ~2000
  call-sites would be unreadable). Alias convention: standard short names for
  stdlib (`BS` for `Data.ByteString(.Char8)`, `Map`, `Char`, `List`, `Maybe`,
  `Word`, `IORef`, `Monad`, `MVar`, ...) and the last path segment for
  project/`Foreign` modules (`Http`, `Router`, `Iteratee`, `Ptr`, ...). Where two
  modules share a last segment, the framework one keeps the short alias and the
  application one is distinguished (`MicroHttp.Config` = `Config`, `Verso.Config`
  = `VConfig`). A module that re-exports another module's names keeps a separate
  unqualified import just for the re-exported list.
- **Every top-level binding in `src/` carries a Haddock comment.** Test functions
  and local `where`/`let` helpers are exempt.
- **`MicroHttp.Http` is a single module**: `Framing`, `Parser`, `PercentEncoding`,
  and `Response` were inlined into it. `MicroHttp.Http.Parse` stays separate (the
  `Http` <-> `Stream` cycle-breaker, ADR/RFC-0031) and its types are re-exported
  by `MicroHttp.Http`.

## Consequences

more verbose use-sites (qualified prefixes) in exchange for
unambiguous name origin; the `test/ghc-compat/` shims are out of scope
(GHC-coverage-only). New code should follow the alias convention.
