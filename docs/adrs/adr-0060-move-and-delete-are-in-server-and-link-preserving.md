---
id: ADR-0060
name: Move and Delete Are In-Server and Link-Preserving
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0027]
---

# ADR-0060: Move and Delete Are In-Server and Link-Preserving

> Status: Accepted (RFC-0027).

## Context

RFC-0026 deferred rename/move/delete to an external move-utility that
would reconcile links and sidecar metadata. The owner reversed that: the
reconciliation is wanted in-server so the external tracker can be retired. The
served tree is gitignored, so there is no git net for the link breakage a naive
move would cause.

## Decision

move and delete are server endpoints under `/tree`, and the server
preserves relative-link integrity itself. A move rewrites every relative `.md`/
`assets/` link across the tree whose resolved target moved (a general whole-tree
re-resolution, `planMoveRewrites`, not a boundary special case, so a move that also
renames fixes internal `../<oldname>/` links too), co-moves the sidecar meta
directory, and **relocates** the moved item's entry between the source and
destination parent `index.md` listings (those two files are excluded from the
generic rewrite so the entry moves rather than being repointed in place). This
supersedes RFC-0026's external-utility reconciliation contract.

## Consequences

the tree can be reorganised in place without leaving dangling links,
and the tracker tool leaves the loop. The cost is a whole-tree scan per operation
(~3,900 page reads + link parse), run behind the preview/confirm; an index is a
later optimisation. Recovery (undo, trash, replay) is layered on by RFC-0028.
