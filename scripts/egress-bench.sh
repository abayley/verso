#!/usr/bin/env bash
# Egress (send-path) throughput against a plain-sendAll baseline, under the same
# saturated two-process harness as the ingress benches with roles swapped: the
# MicroHs sender (the subject) listens and sends each method's stream, while a
# GHC blocking drainer keeps the pipe empty. The sender runs once per method;
# the GHC drainer connects once per method.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
# The package database is normally passed by the Makefile bench target so
# the version is defined in one place.
DB="${MHS_PACKAGE_DB:-$HOME/.mcabal/mhs-0.16.3.0}"
PORT=8090
METHODS=2

mkdir -p "$BUILD"

# Sender: MicroHs, the subject under test.
cc -O2 -Wall -c "$ROOT/cbits/microhttp_fs.c" -o "$BUILD/microhttp_fs.o" -I"$ROOT/cbits"
mhs -a"$DB" -optc -I"$ROOT/cbits" -optl "$BUILD/microhttp_fs.o" -i"$ROOT/src" -i"$ROOT/bench" "$ROOT/bench/EgressSender.hs" -o "$BUILD/egress-sender"

# Drainer: GHC + network, blocking reads.
(cd "$ROOT/bench/sender" && cabal build >/dev/null 2>&1)
DRAIN="$(cd "$ROOT/bench/sender" && cabal list-bin socket-drain)"

"$BUILD/egress-sender" &
SEND_PID=$!
trap 'kill "$SEND_PID" 2>/dev/null || true' EXIT

# One drainer run per method; the sender serves them in sequence.
for _ in $(seq "$METHODS"); do
    "$DRAIN" "$PORT"
done
wait "$SEND_PID"
