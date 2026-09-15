#!/usr/bin/env bash
# End-to-end HTTP request-rate benchmark for the Verso server. It builds and
# starts the server on a private port, then drives it with ApacheBench (ab) over
# new connections (the server sends Connection: close), comparing the in-memory
# builder path (StrictBody) against the zero-copy sendfile path (FileBody) at a
# few payload sizes. Numbers are relative: the server and ab share the host and
# MicroHs is interpreted, so treat them as a regression signal, not production
# figures. See docs/http-benchmark.md.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
# The package database is normally passed by the bench-http Makefile target so
# the version is defined in one place.
DB="${MHS_PACKAGE_DB:-$HOME/.mcabal/mhs-0.16.5.0}"
# Linker options for mhs (the Makefile passes the CLT-ld override where the toolchains disagree).
LINK="${MHS_LINK_FLAGS:-}"

PORT="${MICROHTTP_BENCH_PORT:-8099}"
CONC="${MICROHTTP_BENCH_CONC:-16}"
N_SMALL="${MICROHTTP_BENCH_N_SMALL:-3000}"
N_LARGE="${MICROHTTP_BENCH_N_LARGE:-800}"
HOST=127.0.0.1
BASE="http://$HOST:$PORT"

command -v ab >/dev/null 2>&1 || { echo "ab (ApacheBench) not found on PATH" >&2; exit 1; }
command -v mhs >/dev/null 2>&1 || { echo "mhs not found on PATH" >&2; exit 1; }

mkdir -p "$BUILD"
# Link the cbits the server needs: the filesystem syscall wrappers and the
# concordance stub (search stays off in a bench; no index worker interference).
# Built to verso-bench so the user's real build/verso is not clobbered.
cc -O2 -Wall -c "$ROOT/cbits/microhttp_fs.c" -o "$BUILD/microhttp_fs.o" -I"$ROOT/cbits"
cc -O2 -Wall -c "$ROOT/cbits/concordance_stub.c" -o "$BUILD/concordance_stub_bench.o" -I"$ROOT/cbits"
mhs -a"$DB" $LINK -optc -I"$ROOT/cbits" -optl "$BUILD/microhttp_fs.o" -optl "$BUILD/concordance_stub_bench.o" \
    -i"$ROOT/src" "$ROOT/src/Verso/Main.hs" -o "$BUILD/verso-bench"

# A private config so the user's micro-http.conf and port 8080 are untouched.
CONF="$(mktemp)"
SNAPSHOT="$ROOT/packages/verso/static/editor/_bench-snapshot.html"
cat >"$CONF" <<EOF
host = $HOST
port = $PORT
document_root = data/documents
EOF

cleanup() {
    [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null || true
    rm -f "$CONF" "$SNAPSHOT"
}
trap cleanup EXIT

# Start the server from ROOT (its static/document roots are relative).
( cd "$ROOT" && MICROHTTP_CONFIG="$CONF" "$BUILD/verso-bench" ) &
SERVER_PID=$!

# Wait for the port to accept requests. mhs buffers stdout, so poll the socket,
# not the log. macOS has no timeout(1), so bound the wait with an attempt count.
ready=
for _ in $(seq 1 100); do
    if curl -fs -o /dev/null "$BASE/"; then ready=1; break; fi
    sleep 0.1
done
[ -n "$ready" ] || { echo "server did not come up on $BASE" >&2; exit 1; }

# Snapshot the built index page to a static file: a byte-identical body served
# by the sendfile path, isolating builder-vs-sendfile from payload differences.
curl -fs "$BASE/" -o "$SNAPSHOT"

bench() { # label path n
    local rps failed xfer
    local out
    out="$(ab -n "$3" -c "$CONC" -q "$BASE$2" 2>/dev/null)"
    rps="$(printf '%s\n' "$out" | awk -F'[ :]+' '/Requests per second/ {print $4}')"
    failed="$(printf '%s\n' "$out" | awk -F'[ :]+' '/Failed requests/ {print $3}')"
    xfer="$(printf '%s\n' "$out" | awk -F'[ :]+' '/Transfer rate/ {print $3}')"
    printf '  %-34s n=%-5s c=%-3s  %8s req/s  %6s KB/s  failed=%s\n' \
        "$1" "$3" "$CONC" "${rps:-?}" "${xfer:-?}" "${failed:-?}"
}

echo "MicroHttp HTTP bench  ($BASE, Connection: close, ab)"
ab -n 200 -c 8 -q "$BASE/" >/dev/null 2>&1   # warmup
bench "builder / (StrictBody)"        "/"                                       "$N_SMALL"
bench "sendfile snapshot (FileBody)"  "/static/editor/_bench-snapshot.html"     "$N_SMALL"
bench "sendfile css (~8KB)"           "/static/editor/markdown-editor.css"      "$N_SMALL"
bench "sendfile js (~1.5MB)"          "/static/editor/markdown-editor.js"       "$N_LARGE"
