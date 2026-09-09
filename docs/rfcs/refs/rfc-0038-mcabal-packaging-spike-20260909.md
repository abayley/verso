# RFC-0038 Phase 0: MicroCabal Packaging Spike (2026-09-09)

Supporting material for [RFC-0038](../rfc-0038-repository-package-structure.md). Records the Phase 0
feasibility spike: can `micro-http` become a MicroCabal package, with its C FFI sources, that the Verso
application depends on through the package database? Result: yes, proven end to end. No production files were
changed; the spike ran under `spike/mcabal-package/`.

## Question

Can a MicroCabal (`mcabal`) library package carry the framework's C sources so that its FFI links into a
separate dependent package, and does a dependent resolve a locally installed, non-snapshot package by name?

## Result

Proven, twice. A trivial library and then the real `micro-http` module set were each installed as a package
and consumed by a separate package that called their FFI.

- Trivial package: a library with one C source and a `foreign import` was installed with `mcabal install`;
  a separate `executable` package with `build-depends: micro-spike` built and ran it (`spikeAdd 2 3 = 5`).
- Real package: a `micro-http.cabal` listing all fifteen `MicroHttp` modules, the two C sources
  (`microhttp_fs.c`, `microhttp_process.c`), and `build-depends: base, mtl`, installed cleanly. A separate
  package with `build-depends: micro-http` called `MicroHttp.FileSystem.fileStat "/etc/hosts"`, which runs
  the `mhfs_stat` FFI, and it returned the real size (`fileStat /etc/hosts OK, size=237`).

This exercises the whole mechanism: the dependent's build compiles the dependency's C sources and links
them, the FFI symbol resolves at runtime, and `build-depends` finds a locally installed package with no
path or git dependency.

## Requirements learned

Three concrete requirements for packaging `micro-http`:

1. **Headers go in a separate `include-dirs` directory, named in `install-includes`.** A header left beside
   the `.c` file in the `c-sources` directory was not installed into the package, so the dependent's link
   failed with "header not found". Moving it to an `include/` directory with `include-dirs: include` and
   `install-includes: <header>` installed it (the same shape the `time` package uses). The project's cbits
   headers (`microhttp_fs.h`, `microhttp_process.h`) currently sit beside their `.c` files in `cbits/`, so
   packaging moves them to a sibling `include/` directory.
2. **Foreign imports must name the header in the import string.** `foreign import ccall "microhttp_fs.h
   mhfs_stat"` makes mhs emit `#include "microhttp_fs.h"` in the generated stub, which is what supplies the
   declaration at link. The project's foreign imports already do this, so no code changes are needed.
3. **`build-depends` for `micro-http` is `base, mtl`.** `base` provides `Data.ByteString`, the `System.IO.*`
   modules, `Foreign.*`, and the rest; `mtl` provides `Control.Monad.Except`. No other package is needed.

## What this does not cover

- Concordance's native linking (lancedb, onnxruntime, conditional shim/stub, rpath) was deliberately not
  packaged: the decision is to keep Concordance inside the Verso package, where its existing Makefile-driven
  linking is unchanged. This spike therefore did not need to answer the hardest packaging question.
- The full Verso application build against an installed `micro-http` (rather than a one-module consumer) is
  Phase 3 work. The spike proves the mechanism and the `micro-http` package specifically.

## Reproduction

Under `spike/mcabal-package/`: `micro-spike/` and its `consumer/` are the trivial case; `micro-http-real/`
holds the real `micro-http.cabal` (sources referenced in place) and `micro-http-real/consumer/` the FFI
consumer. `mcabal install` in a library directory, then `mcabal build` in the consumer. The spike installs
were removed from `~/.mcabal/mhs-0.16.5.0/packages/` afterwards so they do not shadow the working build.
