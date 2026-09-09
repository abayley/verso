---
id: ADR-0078
name: Subprocesses via posix_spawn, Not fork+exec
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0078: Subprocesses via posix_spawn, Not fork+exec

> Status: Accepted (2026-07-11). Amends the mechanism behind ADR-0070's subprocess runner; the argv-vector contract is unchanged.

## Context

`MicroHttp.Process` ran git commits via raw `fork(2)` +
`execvp(3)` + `waitpid(2)`. With search enabled the same process hosts
LanceDB's tokio runtime and ONNX thread pools, and `fork` clones only
the calling thread: on a live server the forked child resumed the
MicroHs green-thread scheduler before reaching exec, ran the search
queue worker's next LanceDB call on post-fork state, and parked forever
on tokio workers that no longer existed -- while the parent blocked in
`waitpid` (uninterruptible by SIGINT), wedging the whole server on any
structural write. Confirmed by `sample` backtraces of a hung server
(child in `cn_store_pages -> tokio block_on -> condvar`, parent in
`mhs_waitpid -> __wait4`).

## Decision

Spawn subprocesses with `posix_spawnp(3)` behind a cbits
wrapper (`mhp_spawn` in cbits/microhttp_process.c, the same
folded-errno pattern as microhttp_fs.c). The opaque
`posix_spawn_file_actions_t` carries the stdio redirections and the
working-directory change, so no user code -- and no green-thread
scheduling -- ever runs in the child; a spawn failure reports exit 127,
matching the old exec-failure convention. The parent still `waitpid`s
and reads the capture files back.

## Consequences

Structural writes can no longer deadlock against the
search runtime; the fork-to-exec window where the interpreter could run
in the child is gone by construction. The fix is not regression-testable
at a deterministic in-suite seam (it would need the real tokio runtime
plus a one-scheduler-quantum race), so the guard is behavioural: the
`MicroHttp.Process` unit seam pins the runProcess contract (including
exit 127 for a missing executable), and test/bench/hang-repro.sh drives a
live search-enabled server through publish/create/delete storms and
fails on any wedge, crash, or leftover fork child.
`posix_spawn_file_actions_addchdir_np` requires macOS 10.15+ / glibc
2.29+ (and `_GNU_SOURCE` on glibc), within the project's platform
floor.
