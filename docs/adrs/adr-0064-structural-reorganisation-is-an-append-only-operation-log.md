---
id: ADR-0064
name: Structural Reorganisation Is an Append-Only Operation Log
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0028]
---

# ADR-0064: Structural Reorganisation Is an Append-Only Operation Log

> Status: Accepted (RFC-0028).

## Context

the served tree is gitignored and is periodically re-exported from an
authoritative source in its original layout, overwriting the author's in-app
reorganisation. The moves and deletes need to be durable (to replay after a refresh)
and reversible (undo), neither of which git or a versioning store provides here.

## Decision

capture each structural operation as one line in an append-only
**operation log** held outside the corpus at a configured path (`operation_log`).
A line is the *logical* operation -- type (`move`/`delete`/`restore`), kind
(`page`/`section`), `from`/`to` paths, a monotonic `seq`, a caller-stamped `ts`, and
a `trash` id for delete/restore -- not the file-by-file rewrites, which RFC-0027's
machinery recomputes when the operation is applied (live, on undo, or on replay).
The write order is **apply-then-append**. Undo is **append-inverse** (the inverse is
just another logged operation), not a popped stack, so the log is a faithful history
and replay reproduces the net state.

## Consequences

the log replays onto a refreshed corpus to re-impose the
reorganisation, and undo/redo are uniform. A crash between apply and append loses at
most one log entry (never corrupts the tree). The log is structural intent only --
creates are not logged and content history is out of scope (a refresh supplies
content).
