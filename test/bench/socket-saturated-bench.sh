#!/usr/bin/env bash
# Saturated loopback throughput for MicroHttp.Network.Socket: a GHC blocking
# sender keeps the pipe full while the MicroHs receiver drains it through the
# production recv loop, isolating the recv ceiling from the single-threaded
# poll-bound ping-pong of bench/SocketBench.hs. The receiver prints the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
# The package database is normally passed by the Makefile bench target so
# the version is defined in one place.
DB="${MHS_PACKAGE_DB:-$HOME/.mcabal/mhs-0.16.3.0}"
PORT=8090
BYTES="${1:-$((512 * 1024 * 1024))}"

mkdir -p "$BUILD"

# Receiver: MicroHs, the subject under test.
cc -O2 -Wall -c "$ROOT/cbits/microhttp_fs.c" -o "$BUILD/microhttp_fs.o" -I"$ROOT/cbits"
mhs -a"$DB" -optc -I"$ROOT/cbits" -optl "$BUILD/microhttp_fs.o" -i"$ROOT/src" -i"$ROOT/test/bench" "$ROOT/test/bench/SocketReceiver.hs" -o "$BUILD/socket-receiver"

# Sender: GHC + network, blocking sends.
(cd "$ROOT/test/bench/sender" && cabal build >/dev/null 2>&1)
SENDER="$(cd "$ROOT/test/bench/sender" && cabal list-bin socket-sender)"

# Start the receiver, then the sender (which retries the connect past the
# startup race). Clean up the receiver if anything fails.
"$BUILD/socket-receiver" &
RECV_PID=$!
trap 'kill "$RECV_PID" 2>/dev/null || true' EXIT

"$SENDER" "$PORT" "$BYTES"
wait "$RECV_PID"
