---
id: ADR-0062
name: Cross-Folder Page Moves Classify Assets Shared vs Exclusive
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0027]
---

# ADR-0062: Cross-Folder Page Moves Classify Assets Shared vs Exclusive

> Status: Accepted (RFC-0027). Scope: realised in phase 3 (page move); recorded here with the move contract.

## Context

pages in a folder share one `assets/` directory. Moving a single page
across folders must decide what happens to each asset it references: copying all of
them duplicates assets siblings still use, while moving a shared asset breaks those
siblings.

## Decision

classify each asset the moving page references (the union of its body
`assets/<name>` refs and its sidecar image/attachment entries, so an unlinked
attachment still travels) by scanning all peer pages' bodies and sidecars. An
**exclusive** asset (no sibling references it) is relocated to the destination; a
**shared** asset is copied (the source copy stays). Destination name collisions
dedup by content (the `storeAsset` rule).

## Consequences

a page move keeps its own assets working at the destination without
breaking siblings and without needless duplication. Classification reads bodies
(authoritative) cross-checked with sidecars, so a body-only reference is never
mistaken for exclusive.
