#!/usr/bin/env bash
# Resident-memory high-water mark of the Verso server under a fixed scenario
# set (RFC-0043). The MicroHs heap is a fixed arena, but ByteString payloads
# and the C side live outside it, so the process's peak RSS is the number the
# heap setting cannot bound; this script measures it.
#
# It builds build/verso through the Makefile, starts it on a private port at
# VERSO_HEAP_CELLS against a corpus, samples RSS every 100ms for the life of
# the run, and drives one scenario at a time, printing the absolute peak and
# the peak above the pre-scenario baseline for each. One scenario at a time
# and one upload at a time, with a hard abort past MICROHTTP_BENCH_ABORT_MB:
# concurrent large uploads once took this workstation down.
#
#   MICROHTTP_BENCH_TREE          the document tree; default: a scratch copy of
#                                 the search-demo corpus (the mutating scenarios
#                                 write into it)
#   MICROHTTP_BENCH_READONLY=1    run only the read scenarios (for a real corpus)
#   MICROHTTP_BENCH_UPLOAD_BYTES  raw asset upload size; default 8 MiB (cap 10 MiB)
#   MICROHTTP_BENCH_ABORT_MB      kill the server past this RSS; default 1500
#   VERSO_HEAP_CELLS              the heap, as for make run-verso; default 8000000
#
# Run via `make bench-memory` (which passes VERSO_HEAP_CELLS).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD="$ROOT/build"
WORK="$BUILD/memory-bench"
PORT="${MICROHTTP_BENCH_PORT:-8098}"
HOST=127.0.0.1
BASE="http://$HOST:$PORT"
HEAP="${VERSO_HEAP_CELLS:-8000000}"
UPLOAD_BYTES="${MICROHTTP_BENCH_UPLOAD_BYTES:-$((8 * 1024 * 1024))}"
ABORT_MB="${MICROHTTP_BENCH_ABORT_MB:-1500}"
READONLY="${MICROHTTP_BENCH_READONLY:-0}"

command -v curl >/dev/null 2>&1 || { echo "curl not found on PATH" >&2; exit 1; }
if lsof -ti tcp:"$PORT" >/dev/null 2>&1; then
    echo "port $PORT is already in use (a previous server still running?); set MICROHTTP_BENCH_PORT or stop it" >&2
    exit 1
fi

# --- the corpus -------------------------------------------------------------
rm -rf "$WORK"
mkdir -p "$WORK"
if [ -n "${MICROHTTP_BENCH_TREE:-}" ]; then
    TREE="$MICROHTTP_BENCH_TREE"
else
    [ -d "$BUILD/search-demo/tree" ] || { echo "no search-demo corpus at $BUILD/search-demo/tree (run make run-verso-search-demo once)" >&2; exit 1; }
    TREE="$WORK/tree"
    cp -R "$BUILD/search-demo/tree" "$TREE"
fi
# The largest page, tree-relative, is the subject of the read and save scenarios.
# (sorted to a file first: a head at the end of this pipeline would SIGPIPE sort under pipefail)
find "$TREE" -name '*.md' -type f -print0 | xargs -0 stat -f '%z %N' | sort -rn >"$WORK/sizes"
BIG_FS="$(head -1 "$WORK/sizes" | cut -d' ' -f2-)"
BIG_REL="${BIG_FS#"$TREE"/}"
BIG_BYTES="$(stat -f '%z' "$BIG_FS")"

CONF="$WORK/bench.conf"
cat >"$CONF" <<EOF
host = $HOST
port = $PORT
document_tree_root = $TREE
operation_log = $WORK/oplog
trash_root = $WORK/trash
link_index = $WORK/linkindex
draft_root = $WORK/drafts
access_log = $WORK/access.log
client_error_log = $WORK/client-errors.log
search_enabled = false
EOF

# --- the server and the sampler --------------------------------------------
(cd "$ROOT" && make -s "$BUILD/verso" >/dev/null)

SAMPLES="$WORK/rss.samples"
: >"$SAMPLES"
: >"$WORK/windows"
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }

SERVER_PID=
SAMPLER_PID=
TIME_PID=
cleanup() {
    [ -n "$SAMPLER_PID" ] && kill "$SAMPLER_PID" 2>/dev/null || true
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    [ -n "$TIME_PID" ] && kill "$TIME_PID" 2>/dev/null || true
}
trap cleanup EXIT

start_server() {
    (cd "$ROOT" && MICROHTTP_CONFIG="$CONF" exec /usr/bin/time -l "$BUILD/verso" +RTS -H"$HEAP" -RTS >"$WORK/server.log" 2>"$WORK/time.log") &
    TIME_PID=$!
    # the server is time(1)'s child; sample and stop that, and time reports when it exits
    SERVER_PID=
    # found by its own command line (anchored, so time(1)'s line, which also contains it, does not match)
    for _ in $(seq 1 100); do
        SERVER_PID="$(pgrep -n -f "^$BUILD/verso \+RTS -H$HEAP" 2>/dev/null || true)"
        [ -n "$SERVER_PID" ] && break
        sleep 0.05
    done
    [ -n "$SERVER_PID" ] || { echo "could not find the server process under time(1)" >&2; exit 1; }
    (
        while kill -0 "$SERVER_PID" 2>/dev/null; do
            rss_kb="$(ps -o rss= -p "$SERVER_PID" 2>/dev/null | tr -d ' ' || true)"
            [ -n "$rss_kb" ] && echo "$(now) $rss_kb" >>"$SAMPLES"
            if [ -n "$rss_kb" ] && [ "$rss_kb" -gt $((ABORT_MB * 1024)) ]; then
                echo "ABORT: RSS ${rss_kb}KB passed ${ABORT_MB}MB; killing the server" >&2
                kill "$SERVER_PID" 2>/dev/null || true
                exit 1
            fi
            sleep 0.1
        done
    ) &
    SAMPLER_PID=$!
}

wait_ready() {
    for _ in $(seq 1 600); do
        if curl -fs -o /dev/null "$BASE/documents/index.md"; then return 0; fi
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "the server exited during startup; see $WORK/server.log" >&2
            exit 1
        fi
        sleep 0.1
    done
    echo "server did not come up on $BASE; see $WORK/server.log" >&2
    exit 1
}

# peak_between <from> <to>: the largest sample in the window, in MB.
peak_between() {
    awk -v from="$1" -v to="$2" '$1 >= from && $1 <= to && $2 > max { max = $2 } END { printf "%.0f", max / 1024 }' "$SAMPLES"
}
# last_before <t>: the most recent sample before t, in MB (the scenario's baseline).
last_before() {
    awk -v t="$1" '$1 < t { last = $2 } END { printf "%.0f", last / 1024 }' "$SAMPLES"
}

printf 'memory bench: heap %s cells, corpus %s, largest page %s (%s bytes)\n' "$HEAP" "$TREE" "$BIG_REL" "$BIG_BYTES"
# ps(1)'s RSS on macOS excludes pages the memory compressor has taken, so it can dip
# between requests; the per-scenario peak is the figure, the baseline is shown for
# context, and time(1)'s maximum resident set at the end is the kernel's own high-water mark.
printf '%-44s | %9s | %9s\n' "scenario" "peak MB" "base MB"

run_scenario() { # label command...
    local label="$1"; shift
    sleep 1 # settle: let the previous scenario's samples land
    local from base to
    from="$(now)"
    base="$(last_before "$from")"
    "$@"
    sleep 0.5
    to="$(now)"
    local peak
    peak="$(peak_between "$from" "$to")"
    printf '%-44s | %9s | %9s\n' "$label" "$peak" "$base"
    awk -v from="$from" -v to="$to" -v label="$label" -v base="$base" '$1 >= from && $1 <= to { n++; if (min == "" || $2 < min) min = $2 } END { printf "%s: base %sMB, %d samples, min %.0fMB\n", label, base, n, min / 1024 }' "$SAMPLES" >>"$WORK/windows"
}

# 1. cold start: the link-index build with no persisted index.
rm -f "$WORK/linkindex"
T0="$(now)"
start_server
wait_ready
T1="$(now)"
printf '%-44s | %9s | %9s\n' "1 cold start (link-index build)" "$(peak_between "$T0" "$T1")" "-"

# req <curl args...>: a request whose failure is reported, not fatal (the peak is still measured).
req() {
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "$@")"
    case "$code" in 2*|3*) ;; *) echo "  request returned $code: ${*: -1}" >&2 ;; esac
}
get_edit() { req "$BASE/documents/$BIG_REL?edit"; }
seq_reads() { for _ in $(seq 1 12); do get_edit; done; }
conc_reads() { # wait on the readers by pid: a bare wait would also wait on the sampler
    local pids=()
    for _ in 1 2 3 4; do get_edit & pids+=($!); done
    wait "${pids[@]}"
}

run_scenario "2 twelve sequential edit-view reads" seq_reads
run_scenario "3 four concurrent edit-view reads" conc_reads

if [ "$READONLY" != "1" ]; then
    UPLOAD="$WORK/upload.md"
    perl -e 'print "markdown body line\n" x int($ARGV[0] / 19)' "$UPLOAD_BYTES" >"$UPLOAD" # a pipe here would SIGPIPE under pipefail
    # the asset upload is the raw-body path with the largest cap (treeAssetMaxBytes, 10 MiB);
    # a document PUT is capped at formBodyLimit (1 MiB)
    raw_put() { req -X POST -H 'X-Attachment-Filename: bench-upload.txt' --data-binary "@$UPLOAD" "$BASE/documents/$BIG_REL?asset"; }
    form_save() { req -X POST --data-urlencode "markdown@$BIG_FS" "$BASE/documents/$BIG_REL"; }
    BIG_DIR="$(dirname "$BIG_REL")"
    [ "$BIG_DIR" = "." ] && BIG_DIR=""
    OTHER_DIR="$(find "$TREE" -mindepth 1 -maxdepth 1 -type d ! -name assets ! -name "$BIG_DIR" | head -1)"
    OTHER_DIR="${OTHER_DIR#"$TREE"/}"
    move_and_back() {
        local name; name="$(basename "$BIG_REL")"
        req -X POST -d "to=$OTHER_DIR" -d "confirm=true" "$BASE/tree/$BIG_REL?move"
        req -X POST -d "to=$BIG_DIR" -d "confirm=true" "$BASE/tree/$OTHER_DIR/$name?move"
    }

    run_scenario "4 one raw asset upload of $((UPLOAD_BYTES / 1024 / 1024)) MiB" raw_put
    run_scenario "5 one no-JS form save of the largest page" form_save
    if [ -n "$OTHER_DIR" ]; then
        run_scenario "6 move the largest page away and back" move_and_back
    else
        printf '%-44s | %9s | %9s\n' "6 move (skipped: no second directory)" "-" "-"
    fi
fi

sleep 1
printf '%-44s | %9s | %9s\n' "final (after settle)" "$(last_before "$(now)")" "-"
# stop the server so time(1) reports; its maximum resident set is the kernel's own high-water mark
kill "$SERVER_PID" 2>/dev/null || true
wait "$TIME_PID" 2>/dev/null || true
maxrss="$(awk '/maximum resident set size/ { printf "%.0f", $1 / 1048576 }' "$WORK/time.log")"
printf '%-44s | %9s | %9s\n' "kernel maximum resident set (time -l)" "${maxrss:-?}" "-"
printf 'samples: %s (%s taken); windows: %s\n' "$SAMPLES" "$(wc -l <"$SAMPLES" | tr -d ' ')" "$WORK/windows"
