#!/usr/bin/env bash
# Egress (send-path) throughput against a plain-sendAll baseline, under the same
# saturated two-process harness as the ingress benches with roles swapped: the
# MicroHs sender (the subject) listens and sends each method's stream, while a
# GHC blocking drainer keeps the pipe empty. The sender runs once per method;
# the GHC drainer connects once per method.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
# The package database is normally passed by the Makefile bench target so
# the version is defined in one place.
DB="${MHS_PACKAGE_DB:-$HOME/.mcabal/mhs-0.16.5.0}"
# Linker options for mhs (the Makefile passes the CLT-ld override where the toolchains disagree).
LINK="${MHS_LINK_FLAGS:-}"
PORT=8090
METHODS=2

mkdir -p "$BUILD"

# Sender: MicroHs, the subject under test.
# The framework and its C shims come from the installed micro-http package (RFC-0038).
mhs -a"$DB" $LINK -i"$ROOT/test/bench" "$ROOT/test/bench/EgressSender.hs" -o "$BUILD/egress-sender"

# Drainer: GHC + network, blocking reads.
DRAIN="$("$ROOT/test/bench/build-sender.sh" socket-drain)"

"$BUILD/egress-sender" &
SEND_PID=$!
trap 'kill "$SEND_PID" 2>/dev/null || true' EXIT

# One drainer run per method; the sender serves them in sequence.
for _ in $(seq "$METHODS"); do
    "$DRAIN" "$PORT"
done
wait "$SEND_PID"
