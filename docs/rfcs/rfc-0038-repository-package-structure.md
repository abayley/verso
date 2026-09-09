---
id: RFC-0038
name: Repository package structure and Haskell/TypeScript separation
status: Draft
owners:
    - Alistair Bayley
created: 2026-09-09
updated: 2026-09-09
supersedes: []
superseded_by: null
related_rfcs: [RFC-0030]
related_refs:
    - docs/rfcs/refs/rfc-0038-build-coupling-inventory-20260909.md
    - docs/rfcs/refs/rfc-0038-mcabal-packaging-spike-20260909.md
---

# RFC-0038: Repository package structure and Haskell/TypeScript separation

## Summary

Restructure the repository so that application code lives in real packages, dev and quality tooling lives
in `scripts/`, and the Haskell and TypeScript codebases are physically separate. Turn the framework into a
standalone MicroHs package (`micro-http`) that the Verso application depends on through the MicroCabal
package database. The search library (`Concordance.*`) stays inside the Verso package, so its delicate
native linking is untouched. Move the TypeScript editor out of `src/Verso/Editor` into its own package with
its own toolchain. This is a prepare-for-repo-split step: once `micro-http` is a package Verso only depends
on, extracting it to its own repository becomes a move rather than a disentangling.

Phase 0 (the MicroCabal packaging spike) is done and proved this feasible, including a real `micro-http`
package whose FFI a dependent called successfully. See
`docs/rfcs/refs/rfc-0038-mcabal-packaging-spike-20260909.md`.

## Context

The build has no package boundary today. There is no `.cabal` file; `mhs` is a whole-program compiler and
the `Makefile` wires everything through path variables (`SRC`, `TEST`, `CBITS`, `-i<path>`, `-optl <obj>`).
Every "package" is a directory convention plus include paths. RFC-0030 established the module-level
one-way dependency (`Verso.* -> MicroHttp.*`; `Concordance.*` depends on neither) but left everything in one
`src/` tree built as one program.

Several things now sit in places that do not match how they are used:

- `bench/` holds Haskell benchmark sources, which are test-adjacent, not top-level application code.
- The bench and stress scripts and the browser smoke (`scripts/editor-smoke.cjs`) are test harnesses that
  were living in `scripts/` beside genuine dev tooling.
- `cbits/` holds C FFI implementations for three different owners (MicroHttp filesystem and process, and the
  Concordance search shim) in one flat directory.
- The TypeScript editor lives at `src/Verso/Editor` with its own package manager (bun), linter (biome),
  test runner (vitest), and bundler (esbuild). It shares nothing with the Haskell build but sits inside the
  Haskell source tree.
- `static/` is the editor build output plus vendored CSS and fonts, served by the Verso application at
  runtime.

MicroCabal (`mcabal`) is available and is how MicroHs packages are installed. It parses Cabal files
(`Library`, `executable`, `test-suite`, `hs-source-dirs`, `exposed-modules`, `build-depends`, `c-sources`,
`include-dirs`, `extra-libraries`, `extra-lib-dirs`) and installs a compiled `.pkg` into
`~/.mcabal/mhs-<version>/packages/`. A dependent package resolves it through `build-depends`, and `mhs`
finds installed packages on its package search path (`-a<db>`) and builds a package with `-P`. So a real
package split is expressible: each package gets a `.cabal`, its C sources travel with it, and Verso depends
on `micro-http` and `concordance` by name.

## Goals

- Application code under package `src/`/`test/`; dev and quality tooling under `scripts/`.
- Haskell and TypeScript in physically separate trees with separate, self-contained toolchains.
- `micro-http` is a standalone MicroCabal package with no dependency on Verso or Concordance.
- Verso depends on `micro-http` through the package database, not through a shared source tree.
- `micro-http`'s C sources (`microhttp_fs.c`, `microhttp_process.c`) are owned by the package and expressed
  in its `.cabal`; the Concordance shim and its native linking stay in the Verso build unchanged.
- `make check` stays green after every step, and the whole restructuring lands as small, reversible
  commits.
- The layout makes a future extraction of `micro-http` to its own repository a directory move.

## Non-Goals

- Extracting `micro-http` (or any package) into a separate git repository now. The layout prepares for it;
  the RFC does not do it.
- Publishing any package to a package index.
- Changing runtime behaviour, module contracts, or the module-level dependency direction (RFC-0030 already
  fixes those).
- Rewriting the editor, the search engine, or the framework. This is a physical and build restructuring.
- Adopting Cabal-the-GHC-toolchain. The coverage builds keep using `ghc` directly as they do today; this
  RFC is about MicroCabal packaging.

## Proposal

### Target layout

```text
packages/
  micro-http/       cabal + src/MicroHttp* + cbits/microhttp_fs.c, microhttp_process.c + include/ + test/
  verso/            cabal + src/Verso/* (no Editor) + src/Concordance/* + cbits/concordance_* + test/
                    + static/ (served web assets)
  verso-editor/     package.json + biome/knip/tsconfig/vitest + src/ (was Verso/Editor) + test/
                    + scripts/moebius/ ; builds into ../verso/static/editor/
root:
  Makefile          top-level orchestrator across packages
  scripts/          repo-meta tooling only: generate-adr-index.ts, generate-rfc-index.ts, lib/
  docs/  spike/  patches/  vendor/  data/  package.json (doc tooling only)  and the shared config files
```

`micro-http` exposes the `MicroHttp` and `MicroHttp.*` modules and carries the two unconditional C wrappers
(`microhttp_fs.c`, `microhttp_process.c`), with their headers in a sibling `include/` directory (a Phase 0
requirement, below). `verso` is the application package: it holds `Verso.*` and `Concordance.*`, carries the
search shim and its conditional native linking exactly as the Makefile does today, produces the `verso`
executable, and has `build-depends: micro-http`.

### Packaging mechanism

`micro-http` gets a `.cabal` file. `mcabal install` in its directory compiles it and installs the `.pkg`
into the MicroHs package database. `verso` then builds against it by name: `mhs` resolves the installed
package from its search path, so the Verso build no longer names framework source files, only the package.
Phase 0 confirmed that a dependent's build compiles and links the dependency's C sources and that the FFI
resolves at runtime, and that a locally installed, non-snapshot package resolves through `build-depends`
with no path or git dependency.

Two requirements the spike established for `micro-http` (see the Phase 0 ref):

- The cbits headers must live in a sibling `include/` directory named in `install-includes:`, not beside the
  `.c` files, or `mcabal` does not install them and the dependent's link fails. So `microhttp_fs.h` and
  `microhttp_process.h` move from `cbits/` to `include/`.
- `micro-http`'s `build-depends` is `base, mtl` and nothing else. The foreign imports already name their
  header in the import string, so no source change is needed there.

The `Makefile` becomes a top-level orchestrator: it installs `micro-http` into the database (rebuilding when
its sources change, the way the binaries are file targets today), then builds and tests `verso` against it.
The Concordance shim/stub selection, vendored library paths, rpath, and the GHC coverage linking stay in the
Verso build unchanged, because Concordance stays in the Verso package.

### TypeScript separation

`verso-editor` becomes a top-level package with its own `package.json`, `biome.json`, `knip.json`,
`tsconfig.json`, and `vitest.config.ts`. Its sources are the current `src/Verso/Editor` tree; its tests are
`test/editor`; the Moebius generator moves with it. Its build output continues to land in the Verso app's
served assets (`packages/verso/static/editor/`). The root keeps a small `package.json` for the repo-meta
TypeScript (the ADR/RFC index generators), so there are two package manifests by design: application TS in
its package, repo tooling at the root.

### Tooling and test moves

- `bench/` (Haskell benches) moves under the owning package's `test/bench` (or a package `bench/`), and the
  shell bench and stress scripts move beside them. The browser smoke moves into `verso-editor` (or
  `verso`'s test tree, per Phase 3).
- `scripts/` is left holding only repo-meta tooling: the ADR/RFC index generators and their `lib/`, the
  editor build entry, and the Moebius generator until it moves with the editor.
- `patches/` moves under `vendor/` or `scripts/patches/`; `spike/` stays a top-level throwaway tree.

## Alternatives Considered

- **Directory-level packages without MicroCabal.** Keep raw `mhs` with several `-i` roots
  (`-ipackages/micro-http/src -ipackages/verso/src`). Cheaper and reversible, but the dependency direction
  stays convention-only and it is not a real package boundary, so it does not prepare for a repo split. This
  RFC treats it as the fallback if Phase 0 shows MicroCabal cannot carry the Concordance linking, not the
  goal.
- **Extract `micro-http` to its own repo now.** Rejected as premature: the author is not ready, and a
  package boundary inside one repo captures most of the benefit while staying easy to reverse.
- **Concordance as its own package too.** Splitting the search library into a third package is the tidiest
  end state, but its build is the hard one (patched `lancedb-c` and `onnxruntime` from a vendored directory
  and a Homebrew prefix, a conditional real-shim-versus-stub selection, rpath, and a GHC-spelled variant for
  coverage). Packaging that is a research task in its own right and blocks nothing MicroHttp needs, so
  Concordance stays in the Verso package for now. It can become its own package in a later RFC once
  MicroHttp packaging has settled.
- **One combined package with sub-libraries.** A single `.cabal` with internal libraries for MicroHttp and
  the rest. Keeps one build but does not give MicroHttp an independent identity, so it does not stage the
  repo split.
- **Leave the TypeScript inside `src/`.** Rejected: the toolchains share nothing and the nesting is what
  prompted this work.

## Security Impact

None. No code paths, trust boundaries, or served content change. The restructuring is physical and
build-level.

## Reliability Impact

The risk is entirely in the build: a moved path that is not updated breaks compilation or the served
assets. Keeping Concordance's delicate native linking inside the Verso package means the split does not
disturb it. This is mitigated by keeping `make check` green after every step (it exercises the Haskell
suites, the editor suite, the browser smoke that loads the served bundles, and the chrome gates), and by
de-risking the `micro-http` packaging in Phase 0 before any move. Runtime reliability is unaffected: the
same binaries run the same code.

## Compatibility Impact

Every hardcoded build path that names a moving directory must move with it. The full inventory of coupling
points (Makefile variables and every `mhs`/`ghc`/`cc` invocation; the TypeScript toolchain globs; the
`static/` references from Haskell, config, and views; the cbits include and object paths; and `.gitignore`
entries) is captured in `docs/rfcs/refs/rfc-0038-build-coupling-inventory-20260909.md` and drives the
per-phase checklists in the rollout. Developer-facing compatibility: `INSTALL.md` and the build commands
change (there are now packages to install before the app builds); a preview left running is unaffected.

## Testing and Quality Gates

- `make check` passes after every commit, unchanged in what it verifies.
- After the Haskell split, building `verso` resolves `micro-http` from the package database rather than from
  a shared source tree, proven by a clean build from an empty `build/`.
- The `micro-http` package builds and its tests pass without any Verso or Concordance source on the path
  (proves the dependency direction is real, not conventional). Phase 0 already showed a dependent calling
  `micro-http`'s FFI through the package database.
- The editor package builds, lints, typechecks, and tests in isolation, and its bundle still loads in the
  browser smoke against the served assets.
- The search-enabled build still links the real shim and passes `test/bench/hang-repro.sh`; the default build
  still links the stub and reports search unavailable.
- The GHC coverage builds still run.

## Rollout Plan

Riskiest work is de-risked first, then the independent moves land in order, each as its own small commit
with `make check` green.

- **Phase 0 — MicroCabal spike (no moves). Done (2026-09-09).** Proved that a `.cabal` builds and installs
  `micro-http` with its C sources, that a dependent resolves it through `build-depends` and calls its FFI at
  runtime, and that local non-snapshot resolution needs no path or git dependency. Established the header
  and `build-depends` requirements. Because Concordance now stays in the Verso package, its native linking
  did not need to be packaged. Record: `docs/rfcs/refs/rfc-0038-mcabal-packaging-spike-20260909.md`.
- **Phase 1 — bench and test-script moves. Done (2026-09-09).** Moved the Haskell benches and their four
  driver shell scripts from `bench/` and `scripts/` into `test/bench/`, pointed the Makefile `BENCH`
  variable and the bench targets at the new location, and kept `test/bench` out of the format and lint gate
  so the benches stay ungated as before. The `hang-repro.sh` stress script also moved to `test/bench/`, and
  its references (including two ADRs) were updated to the new path. The `editor-smoke.cjs` browser smoke
  stayed put: it moves with the editor in Phase 2. `make check` stayed green.
- **Phase 2 — TypeScript editor extraction.** Move the editor tree, its tests, the Moebius generator, and
  the TypeScript toolchain into `packages/verso-editor`; point its build output at the Verso app's served
  assets; leave a root `package.json` for the doc tooling.
- **Phase 3 — Haskell package split.** Introduce `packages/micro-http` (with its `.cabal`, its cbits, and
  the headers moved to `include/`) and `packages/verso` (holding `Verso.*` and `Concordance.*` with its
  existing native linking). Convert the Makefile to install `micro-http` and build `verso` against it. This
  is the largest change and rests on Phase 0.
- **Phase 4 (out of scope here, listed for continuity) — repo extraction.** With `micro-http` a package
  Verso only depends on, its extraction to a separate repository becomes a directory move plus a published
  or vendored dependency. A later RFC owns it.

## Open Questions

Resolved by Phase 0:

- MicroCabal resolves a `build-depends` on a locally installed, non-snapshot package with no path or git
  dependency. Confirmed.
- Concordance's conditional native linking does not need to be expressed in a `.cabal`, because Concordance
  stays in the Verso package where the current Makefile linking is unchanged.

Still open:

- Do the GHC coverage builds need their own per-package invocation, or do they keep naming source
  directories directly across the `micro-http` and `verso` trees? (Resolve in Phase 3.)
- Where do the integration tests live once `micro-http` owns its tests: the framework-only ones move with
  it, but the ones that exercise `Verso.*` stay in `verso`; confirm the split before Phase 3.
- Does `bench/` belong under each owning package or under a single top-level `test/bench`? The framework
  benches (socket, iteratee, egress, html-builder) would move with `micro-http`. (Resolve in Phase 1.)
