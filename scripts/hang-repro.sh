#!/bin/bash
# Feedback loop for the fork/tokio server hang (memory: concurrency-hang-git-commit-fork).
#
# Starts verso against the search-demo rig (search enabled, port 8081), then
# drives structural writes that fork git while LanceDB/tokio re-index work is
# in flight on the queue worker. Under the fork+execvp implementation the
# forked child can resume the green-thread scheduler before exec, run the
# queue worker's LanceDB call on post-fork state, and deadlock or abort.
#
# Two phases widen the collision window:
#   1. a publish storm - each publish forks git AND enqueues a large-page
#      re-index, so consecutive publishes race each other's queue work; with
#      HANG_REPRO_FRESH=1 the search index is removed first, so the startup
#      reconcile re-indexes the whole demo tree (~147 pages) while the storm
#      runs.
#   2. create+delete rounds - each create enqueues a re-index, each delete
#      forks git.
#
# Classifies each failure:
#   HANG  - write timed out and the server stayed unresponsive for a further
#           60s (a permanent wedge), and/or a stuck 'build/verso' fork child
#           remains
#   SLOW  - write timed out but the server answered again within 60s (a long
#           stop-the-world GC pause, seen under big-publish load; a separate
#           perf issue, not the fork wedge)
#   CRASH - the server process died (e.g. Rust panic / SIGABRT)
#   HTTP  - the server answered a write with an error status
# GREEN = all writes 2xx (SLOW tolerated with a warning), server alive at the
# end, no stuck child.
#
# Assumes: build/verso already built with the real search shim, port 8081 free.
# Only touches the scratch rig under build/search-demo; never touches a verso
# on any other port.
set -u
cd "$(dirname "$0")/.." || exit 2

PORT=8081
BASE="http://127.0.0.1:$PORT"
LOG="${HANG_REPRO_LOG:-/tmp/hang-repro-server.log}"
ROUNDS="${HANG_REPRO_ROUNDS:-6}"
PUBLISHES="${HANG_REPRO_PUBLISHES:-20}"
BURST=3
TIMEOUT=10

if lsof -tiTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ABORT: port $PORT already in use; refusing to start" >&2
    exit 2
fi

if [ "${HANG_REPRO_FRESH:-}" = "1" ]; then
    rm -rf build/search-demo/index
    echo "removed build/search-demo/index (startup will re-index the whole tree)"
fi

# A multi-section body big enough to make each publish's re-index take a while.
BODY_FILE=$(mktemp /tmp/hang-repro-body.XXXXXX)
{
    for s in $(seq 1 10); do
        echo "# Section $s"
        for _ in $(seq 1 80); do
            echo "The quick brown fox jumps over the lazy dog near the riverbank at dusk while herons watch."
        done
    done
} >"$BODY_FILE"

RUST_BACKTRACE=1 MICROHTTP_CONFIG=build/search-demo.conf ./build/verso >"$LOG" 2>&1 &
launcher_pid=$!

server_pid=""
for _ in $(seq 1 40); do
    server_pid=$(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null | head -1)
    [ -n "$server_pid" ] && break
    sleep 0.5
done
if [ -z "$server_pid" ]; then
    echo "ABORT: server did not start listening; see $LOG" >&2
    kill -9 "$launcher_pid" 2>/dev/null
    exit 2
fi

# Kill only the server we started and any of its stuck fork children.
cleanup() {
    local kids
    kids=$(pgrep -P "$server_pid" 2>/dev/null)
    kill -9 "$server_pid" 2>/dev/null
    for k in $kids; do
        if ps -o command= -p "$k" 2>/dev/null | grep -q 'build/verso'; then
            kill -9 "$k" 2>/dev/null
        fi
    done
    wait "$launcher_pid" 2>/dev/null
    rm -f "$BODY_FILE"
}
trap cleanup EXIT

server_alive() { kill -0 "$server_pid" 2>/dev/null; }

# On the first hang, records the wedged process tree and thread backtraces
# (macOS `sample`) next to the server log, before anything is killed.
evidence_taken=""
capture_hang_evidence() {
    [ -n "$evidence_taken" ] && return 0
    evidence_taken=1
    local dir="${LOG%.log}-evidence" k
    mkdir -p "$dir"
    ps -o pid,ppid,stat,command -p "$server_pid" $(pgrep -P "$server_pid" 2>/dev/null) \
        >"$dir/ps.txt" 2>&1
    sample "$server_pid" 3 -file "$dir/sample-parent.txt" >/dev/null 2>&1
    for k in $(pgrep -P "$server_pid" 2>/dev/null); do
        sample "$k" 3 -file "$dir/sample-child-$k.txt" >/dev/null 2>&1
    done
    echo "  evidence captured in $dir"
}

stuck_children() {
    local out=""
    for k in $(pgrep -P "$server_pid" 2>/dev/null); do
        if ps -o command= -p "$k" 2>/dev/null | grep -q 'build/verso'; then
            out="$out $k"
        fi
    done
    echo "$out"
}

# POSTs and classifies; body form data in $2 (may be empty, or @file for a
# urlencoded markdown field), URL in $1.
hangs=0 crashes=0 httpfails=0 slows=0
post_write() {
    local url=$1 data=$2 label=$3 rc
    if [ -z "$data" ]; then
        curl -sf -o /dev/null --max-time $TIMEOUT -X POST "$url"
    elif [ "${data#@}" != "$data" ]; then
        curl -sf -o /dev/null --max-time $TIMEOUT -X POST \
            --data-urlencode "markdown${data}" "$url"
    else
        curl -sf -o /dev/null --max-time $TIMEOUT -X POST --data "$data" "$url"
    fi
    rc=$?
    [ $rc -eq 0 ] && return 0
    if [ $rc -eq 28 ]; then
        # Timed out: a permanent wedge and a long GC pause look the same at
        # 10s. Probe for recovery before declaring a hang.
        local waited=0
        while [ $waited -lt 60 ]; do
            sleep 5
            waited=$((waited + 5))
            if curl -sf -o /dev/null --max-time 5 "$BASE/tree/"; then
                echo "  SLOW: $label timed out after ${TIMEOUT}s but the server recovered after ~${waited}s"
                slows=$((slows + 1))
                return 0
            fi
            server_alive || break
        done
        if server_alive; then
            echo "  HANG: $label timed out and the server stayed unresponsive for ${waited}s"
            hangs=$((hangs + 1))
            capture_hang_evidence
        else
            echo "  CRASH: $label - server died during the recovery probe"
            crashes=$((crashes + 1))
        fi
    elif ! server_alive; then
        echo "  CRASH: $label - server process died (curl exit $rc)"
        crashes=$((crashes + 1))
    else
        echo "  HTTP: $label failed with curl exit $rc (server alive)"
        httpfails=$((httpfails + 1))
    fi
    return 1
}

stamp="$$$(date +%s)"

# Phase 1: publish storm. Create one page, then publish a large body to it
# repeatedly - each publish forks git while the previous publish's re-index
# (and, with HANG_REPRO_FRESH=1, the startup rebuild) is in flight.
pubpage="hangrepro${stamp}pub"
post_write "$BASE/tree/" "kind=page&title=$pubpage" "publish-page create" || true
for i in $(seq 1 "$PUBLISHES"); do
    post_write "$BASE/documents/$pubpage.md?publish" "@$BODY_FILE" "publish $i" || break
done

# Phase 2: create+delete rounds.
for round in $(seq 1 "$ROUNDS"); do
    for i in $(seq 1 $BURST); do
        title="hangrepro${stamp}r${round}n${i}"
        post_write "$BASE/tree/" "kind=page&title=$title" "round $round create $i" || break 2
    done
    for i in $(seq 1 $BURST); do
        title="hangrepro${stamp}r${round}n${i}"
        post_write "$BASE/tree/$title.md?delete" "" "round $round delete $i" || break 2
    done
done

stuck=$(stuck_children)
verdict=0
if [ "$hangs" -gt 0 ] || [ -n "$stuck" ]; then
    echo "RED (hang): $hangs timeout(s); stuck verso child(ren):${stuck:- none}"
    verdict=1
elif [ "$crashes" -gt 0 ]; then
    echo "RED (crash): server died; see $LOG"
    verdict=1
elif [ "$httpfails" -gt 0 ]; then
    echo "RED (http): $httpfails write(s) rejected; see $LOG"
    verdict=1
else
    [ "$slows" -gt 0 ] && echo "WARN: $slows write(s) hit a long GC pause but recovered"
    echo "GREEN: $PUBLISHES publishes + $ROUNDS rounds of $BURST create+delete answered, server alive, no stuck child"
fi
exit $verdict
