# Installation Guide

This project currently targets MicroHs 0.16.0.0 and uses `mcabal` for MicroHs
package installation. The project is intentionally small, but the test
dependencies still need a few MicroHs-specific steps on a fresh machine.

## Installation Prerequisites

Install or build these tools first:

- MicroHs 0.16.0.0
- MicroCabal 0.5.10.0
- `make`
- `markdownlint-cli2`

### GHC-hosted tools

Although this project uses MicroHs, some development tools still need GHC.

- [ghcup][ghcup]
  This asks several questions; the exact answers do not affect this project
  setup.

Once GHC is installed, use `cabal` to install the other tools:

```shell
cabal install fourmolu
cabal install hlint
cabal install haddock
```

The executables are typically installed to ~/.cabal/bin/, so ensure that is on
your PATH.

[ghcup]: https://www.haskell.org/ghcup/

The current Makefile expects `mhs`, `fourmolu`, `hlint`, and
`markdownlint-cli2` to be visible on `PATH`.

Check the active compiler:

```sh
mhs --version
mcabal --version
fourmolu --version
hlint --version
```

## MicroHs Package Database

`mcabal` installs packages into this package database:

```text
~/.mcabal/mhs-0.16.0.0
```

Some MicroHs builds may otherwise look in:

```text
~/.mcabal-user/mhs-0.16.0.0
```

The project Makefile passes the package database explicitly:

```make
MHS = mhs
MHS_PACKAGE_DB = $(HOME)/.mcabal/mhs-0.16.0.0
MHSFLAGS = -a$(MHS_PACKAGE_DB)
```

Use an absolute or `$HOME`-expanded path with `-a`. Do not pass
`-a~/.mcabal/mhs-0.16.0.0`, because MicroHs treats the tilde literally.

## Test Package Installation

Start by installing the shared dependencies:

```sh
~/.mcabal/bin/mcabal -q -r install call-stack
~/.mcabal/bin/mcabal -q -r install splitmix
~/.mcabal/bin/mcabal -q -r install random
~/.mcabal/bin/mcabal -q -r install containers
~/.mcabal/bin/mcabal -q -r install exceptions
~/.mcabal/bin/mcabal -q -r install HUnit
```

Patch `call-stack` if `hspec-expectations` cannot import `HasCallStack`.
On the local MicroHs 0.16.0.0 setup, `call-stack-0.4.0` only exported
`HasCallStack` when `__GLASGOW_HASKELL__ >= 704`, which MicroHs did not define.

Edit this file:

```text
~/.mcabal/packages/call-stack-0.4.0/src/Data/CallStack.hs
```

Change the export list from this guarded form:

```haskell
module Data.CallStack (
#if __GLASGOW_HASKELL__ >= 704
  HasCallStack,
#endif
```

To this unconditional export:

```haskell
module Data.CallStack (
  HasCallStack,
```

Then reinstall the patched package:

```sh
(
  cd ~/.mcabal/packages/call-stack-0.4.0
  ~/.mcabal/bin/mcabal -q install
)
```

Install the hspec-compatible subset used by the test suite:

```sh
~/.mcabal/bin/mcabal -q -r install hspec-expectations
~/.mcabal/bin/mcabal -q -r install nanospec
```

Install QuickCheck now, ready for property tests later:

```sh
~/.mcabal/bin/mcabal -q install \
  --git=https://github.com/nick8325/quickcheck.git \
  QuickCheck
~/.mcabal/bin/mcabal -q -r install quickcheck-io
```

## Hspec Status

The project imports `Test.Hspec`, but that module is currently provided by
`nanospec`, not by full upstream `hspec`.

Full `hspec` is not part of the current installation path. The current MicroHs
package set makes it fiddly:

- `hspec-core-2.11.16` declares `QuickCheck < 2.18`.
- The MicroHs-compatible QuickCheck package installs as `2.18.0.0`.
- Continuing through the full runner dependency tree hits additional
  MicroHs-unfriendly packages, including `filepath` and `template-haskell`
  related issues.

For now, use the small `nanospec` subset:

- `hspec`
- `describe`
- `context`
- `it`
- `expect`
- `shouldBe`
- `shouldReturn`

## Installation Verification

Check that MicroHs can see the nanospec `Test.Hspec` module:

```sh
cat > /tmp/micro-http-hspec-smoke.hs <<'EOF'
module Main where

import Test.Hspec

main :: IO ()
main =
  hspec $
    describe "smoke" $
      it "works" $
        (1 :: Int) `shouldBe` 1
EOF

mhs \
  -a"$HOME/.mcabal/mhs-0.16.0.0" \
  /tmp/micro-http-hspec-smoke.hs \
  -o /tmp/micro-http-hspec-smoke

/tmp/micro-http-hspec-smoke
```

Check that MicroHs can see QuickCheck:

```sh
cat > /tmp/micro-http-quickcheck-smoke.hs <<'EOF'
module Main where

import Test.QuickCheck

main :: IO ()
main =
  quickCheck (\x -> (x :: Int) == x)
EOF

mhs \
  -a"$HOME/.mcabal/mhs-0.16.0.0" \
  /tmp/micro-http-quickcheck-smoke.hs \
  -o /tmp/micro-http-quickcheck-smoke

/tmp/micro-http-quickcheck-smoke
```

Run the project gate:

```sh
make clean
make check
make clean
```

`make check` runs Markdown linting, Fourmolu format checks, HLint, and all
production tests. Spike compilation is available separately with
`make all-spikes`.
