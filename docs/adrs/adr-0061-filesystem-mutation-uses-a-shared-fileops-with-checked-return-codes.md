---
id: ADR-0061
name: Filesystem Mutation Uses a Shared FileOps With Checked Return Codes
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0027]
---

# ADR-0061: Filesystem Mutation Uses a Shared FileOps With Checked Return Codes

> Status: Accepted (RFC-0027).

## Context

MicroHs's `System.Directory` has no atomic file rename/remove and no
`removeDirectory`, so `MicroHttp.Log` already drove libc `rename`/`unlink` directly
for log rotation, discarding the return codes (best-effort rotation is acceptable).
Move and delete need the same primitives plus `rmdir`, but a failed move or remove
must not silently leave an inconsistent tree.

## Decision

consolidate the libc `rename`/`unlink`/`rmdir` bindings in a single
`MicroHttp.FileOps`, whose wrappers **check the return code** and report success or
failure. `MicroHttp.Log` imports the rename/unlink wrappers from it (still
discarding the result for rotation). Callers validate tree-relative inputs with
`safeComponent`/`resolveStaticPath` before invoking FileOps, which performs no path
validation of its own.

## Consequences

one place owns filesystem mutation; a failed `rename`/`rmdir`
surfaces to move/delete rather than being swallowed (the RFC-0027 reliability
contract). Log rotation's behaviour is unchanged.
