#!/usr/bin/env bash
# Iteratee receive-path throughput against a plain-recv baseline, under the
# same saturated two-process harness as scripts/socket-saturated-bench.sh. The
# MicroHs receiver drains the stream three ways (plain recv, iteratee stream,
# iteratee strict); the GHC blocking sender runs once per consumer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
DB="$HOME/.mcabal/mhs-0.16.0.0"
PORT=8090
BYTES="${1:-$((512 * 1024 * 1024))}"
CONSUMERS=2

mkdir -p "$BUILD"

# Receiver: MicroHs, the subject under test.
mhs -a"$DB" -i"$ROOT/src" -i"$ROOT/bench" "$ROOT/bench/IterateeReceiver.hs" -o "$BUILD/iteratee-receiver"

# Sender: GHC + network, blocking sends.
(cd "$ROOT/bench/sender" && cabal build >/dev/null 2>&1)
SENDER="$(cd "$ROOT/bench/sender" && cabal list-bin socket-sender)"

"$BUILD/iteratee-receiver" &
RECV_PID=$!
trap 'kill "$RECV_PID" 2>/dev/null || true' EXIT

# One sender run per consumer; the receiver accepts them in sequence.
for _ in $(seq "$CONSUMERS"); do
    "$SENDER" "$PORT" "$BYTES"
done
wait "$RECV_PID"
