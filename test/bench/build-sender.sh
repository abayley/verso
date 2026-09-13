#!/usr/bin/env bash
# Builds the GHC load generator (test/bench/sender: socket-sender and
# socket-drain) that the saturated benches pair with the MicroHs binaries.
# Prints the path of the requested executable on stdout.
#
# ghcup's GHC links against the Command Line Tools SDK while gcc resolves to
# Xcode's ld; when the two drift, every link (including hsc2hs's inside the
# network package) fails with "tapi error: malformed file". The Makefile's
# GHC targets link with the CLT's own ld for that reason, and the same
# override is written here as a cabal.project.local so it also reaches the
# dependencies. The build log is kept, not silenced: a sender that fails to
# build used to be invisible.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SENDER_DIR="$ROOT/test/bench/sender"
CLT_LD="/Library/Developer/CommandLineTools/usr/bin/ld"
LOG="$ROOT/build/sender-build.log"
EXE="${1:-socket-sender}"

mkdir -p "$ROOT/build"
if [ -x "$CLT_LD" ]; then
    cat >"$SENDER_DIR/cabal.project.local" <<PROJECT
package *
  ghc-options: -optl-fuse-ld=$CLT_LD
  hsc2hs-options: --lflag=-fuse-ld=$CLT_LD
PROJECT
else
    rm -f "$SENDER_DIR/cabal.project.local"
fi

if ! (cd "$SENDER_DIR" && cabal build all >"$LOG" 2>&1); then
    echo "bench sender build failed; log follows ($LOG)" >&2
    cat "$LOG" >&2
    exit 1
fi
(cd "$SENDER_DIR" && cabal list-bin "$EXE")
