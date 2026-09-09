---
id: ADR-0053
name: Built-In Log Rotation By Size, Rename-Cascade Via Libc FFI
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0053: Built-In Log Rotation By Size, Rename-Cascade Via Libc FFI

## Context

The server's logs (the access log, and now the client-error log of
ADR-0052) are append-only files that grow without bound; an unauthenticated
telemetry endpoint makes unbounded growth a disk-fill concern. The natural fix is
rotation, but two runtime facts constrain it. MicroHs has no atomic `renameFile`
(noted in `MicroHttp.Attachment`), so the classic logrotate rename cannot use
`System.Directory`. And the current logger (`fileLogfmtLogger`) is stateless --
it opens the file per line in append mode -- while connections are `forkIO`'d, so
a rotate interleaved with concurrent appends would lose lines or write to a
rotated file.

## Decision

add built-in rotation to the file logger, applied uniformly to both
logs. Trigger on **size**: when the active file exceeds `log_max_bytes`
(default 10 MB), rotate. Strategy is a **rename-cascade**: `x.log` -> `x.log.1`
-> ... -> `x.log.<log_keep>`, dropping the oldest (`log_keep` default 5).
Renaming, size measurement, and unlinking use **libc FFI** (`rename`, `stat`,
`unlink`), the project's established escape hatch for `System.Directory`/`Data.Time`
gaps (`MicroHttp.Log` already FFIs `localtime`/`strftime`). The check-rotate-append
sequence is serialised by a **per-file `MVar`** created at startup and captured by
the logger closure, so the logger becomes stateful (its constructor moves into
IO, threaded from `main`/`appFromConfig`); each log file has its own lock and
rotates independently.

## Consequences

both logs are bounded to roughly `(log_keep + 1) x log_max_bytes`
on disk, with no external `logrotate` needed. The logger gains shared mutable
state and a small libc FFI surface; app construction gains an IO step to create
the locks. Rotation is best-effort-ordered under load but correct (no lost or
misfiled lines) because of the per-file lock; contention is negligible at the
expected volume. Builds on RFC-0012 (logging as middleware) and the
`MicroHttp.Log` FFI precedent; depended on by ADR-0052. RFC-0024 implements this.
