---
id: RFC-0024
name: Log rotation
status: Implemented
owners:
    - alistairbayley
created: 2026-06-21T15:48+12:00
updated: 2026-06-21T16:02+12:00
supersedes: []
superseded_by: null
---

<!-- Filename: rfc-0024-log-rotation.md -->

# Log rotation

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-06-21 15:48 NZST |
| Started   | 2026-06-21 15:50 NZST |
| Completed | 2026-06-21 16:02 NZST |

## Summary

Add built-in, size-triggered rotation to the server's file logger, applied
uniformly to the access log and the client-error log (RFC-0023). When the active
file exceeds `log_max_bytes` it is rotated by a rename-cascade
(`x.log` -> `x.log.1` -> ... -> `x.log.<log_keep>`, oldest dropped). Renaming,
sizing, and unlinking use libc FFI (no `renameFile` on MicroHs); a per-file
`MVar` serialises rotate-then-append against concurrent connections (ADR-0053).

## Context

The access log and the new client-error log are append-only files that grow
without bound; an unauthenticated telemetry endpoint (RFC-0023) makes that a
disk-fill concern. Two runtime facts constrain the fix: MicroHs has no atomic
`renameFile` (noted in `MicroHttp.Attachment`), and the current logger
(`fileLogfmtLogger`) is stateless -- it opens the file per line in append mode --
while connections are `forkIO`'d, so a rotate interleaved with concurrent
appends would lose lines or misfile them. `MicroHttp.Log` already FFIs libc
(`localtime`/`strftime`), establishing the escape hatch.

## Goals

- Bound each log's disk footprint without an external `logrotate`.
- One mechanism, applied to both the access log and the client-error log.
- Correct under the server's concurrent (`forkIO`-per-connection) model.

## Non-Goals

- Time/age-based rotation (size only; no calendar trigger).
- Compression of rotated files.
- Rotation of anything other than the server's logfmt logs.

## Proposal

- **Trigger**: before appending a line, if the active file's size exceeds
  `log_max_bytes` (config, default 10 MB), rotate first.
- **Strategy**: rename-cascade. Unlink `x.log.<log_keep>` if present; rename
  `x.log.<n>` -> `x.log.<n+1>` for n down to 1; rename `x.log` -> `x.log.1`. The
  next append recreates `x.log`. `log_keep` (config, default 5) bounds the file
  count.
- **Primitives**: libc FFI -- `rename`, `stat` (size), `unlink` -- mirroring the
  `MicroHttp.Log` `localtime`/`strftime` precedent. (`doesFileExist` from
  `System.Directory` may stand in where convenient.)
- **Concurrency**: a per-file `MVar` guards the check-rotate-append sequence. The
  logger constructor becomes IO (it creates the lock) and is threaded from
  `appFromConfig`/`main`; each log file gets its own lock and rotates
  independently. This is the application-owned shared-state pattern (state
  created at startup, captured by the logger closure).
- **Wiring**: `appFromConfig` builds the rotating logger for `access_log` with
  `log_max_bytes`/`log_keep`, and the same constructor backs the client-error
  log (RFC-0023).

## Alternatives Considered

- `System.Directory.renameFile`: unavailable on MicroHs.
- Timestamped new-file rotation (`x-<ts>.log`): avoids rename but needs directory
  listing + age sorting for retention; rename-cascade is simpler and bounded.
- Copy-truncate: copies the whole file each rotation and risks a write between
  copy and truncate; rename is cheaper and atomic per file.
- Stateless best-effort rotation (no lock): rejected -- loses or misfiles lines
  under the concurrent connection model.
- External `logrotate`: rejected for the base case -- the server should bound its
  own logs in a single binary; an operator may still layer their own.

## Security Impact

- Bounds disk consumption from the unauthenticated client-error endpoint
  (RFC-0023), a denial-of-service mitigation.
- The FFI surface is small (`rename`/`stat`/`unlink` on server-controlled paths);
  no user input reaches a path.

## Reliability Impact

- The per-file lock guarantees no lost or misfiled lines across a rotation.
- Failure modes: a rename/unlink error must not crash the logging path -- a
  rotation failure degrades to continuing to append to the active file (logged
  best-effort), never dropping the caller's request.

## Compatibility Impact

- The logger constructor signature moves into IO (internal). The access log's
  on-disk shape gains `.1`..`.N` siblings; consumers reading `access.log`
  directly are unaffected for the active file.

## Testing and Quality Gates

- `make check`.
- Tests: a file exceeding `log_max_bytes` rotates to `.1`; the cascade shifts
  existing archives and drops beyond `log_keep`; concurrent appends across a
  rotation lose no lines; a rotation error falls back to appending.

## Rollout Plan

1. Libc FFI bindings (`rename`/`stat`/`unlink`) and the rotating-file logger with
   a per-file `MVar`.
2. Config keys `log_max_bytes`/`log_keep`; wire the access log through it.
3. Back the client-error log (RFC-0023) with the same constructor.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or ADR-0053 does not cover, stop,
  add the smallest missing decision to `## Open Questions` (or the owning ADR),
  with evidence, impact, options, and a recommendation, and continue only after
  explicit approval.

## Open Questions

- None outstanding; resolved during the RFC-0023 design grilling (see ADR-0053).
