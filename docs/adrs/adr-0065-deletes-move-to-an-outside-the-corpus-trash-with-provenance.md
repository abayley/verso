---
id: ADR-0065
name: Deletes Move to an Outside-the-Corpus Trash With Provenance
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0028]
---

# ADR-0065: Deletes Move to an Outside-the-Corpus Trash With Provenance

> Status: Accepted (RFC-0028).

## Context

with no git net (the tree is gitignored), a hard delete is unrecoverable.
RFC-0027's delete needs a recovery destination, and the destination must survive a
source refresh (which re-exports the corpus in its original layout).

## Decision

a delete moves the target into a configured **trash root** (`trash_root`)
outside the served corpus but on the same filesystem (so it is a single `rename(2)`,
no copy+remove), rather than hard-deleting. The trash entry holds the moved content
-- for a page its `.md`, sidecar meta dir, and exclusive assets (shared assets stay,
per ADR-0062); for a section the whole folder -- plus a provenance manifest recording
each stored item's origin tree path, the kind, the originating log `seq`, and the
removed parent-listing line. **Restore** is the uniform inverse: move each item back
to its origin, refusing if the origin is occupied (prompt for a new location, like a
move collision), re-insert the preserved listing entry, and log a `restore`
operation. Refuse-if-referenced (ADR-0063) still gates a delete -- trash recovers
content but does not fix the dangling links a referenced delete would leave.

## Consequences

deletes are recoverable and survive a refresh; the trash id is the
delete operation's `seq`, so it is unique across move/delete/restore. Trash grows
until manually purged (GC is a non-goal).
