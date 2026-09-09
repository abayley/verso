---
id: ADR-0074
name: Search Freshness by Coalescing Queue Plus Reconcile Sweep
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0034]
---

# ADR-0074: Search Freshness by Coalescing Queue Plus Reconcile Sweep

> Status: Accepted (RFC-0034; extends the ADR-0067 freshness story).

## Context

The search index must track published state (never drafts) without
freezing the server: embedding a page costs tens of milliseconds per chunk
and a whole tree takes minutes.

## Decision

Mutation handlers enqueue work through the same maintenance seam
as the link index: publish/create/direct-save enqueue the page; move,
delete, and restore enqueue a reconcile sweep, which catches every page the
mutation rewrote (referrers, parent listings, relocated subtrees) without
handlers enumerating them. A worker green thread drains the coalescing
queue (pending set; re-enqueueing an in-flight page marks it dirty),
yielding between chunk embeds so a backlog costs stutter, never a freeze.
Freshness is re-established by the sweep -- stat fingerprints first, content
hashes (FNV-1a 64) only for stat-changed pages, re-embedding only real
changes, deleting orphans -- at startup, on `POST /index/refresh` (one
action over all derived indexes), and after structural mutations. The queue
is not durable: a crash costs a catch-up, never correctness. While the
queue is non-empty, search results carry an indexing-in-progress note
rather than being silently incomplete.

The worker also owns **store optimisation**: LanceDB fragments under the
delete-then-add upserts, and optimisation folds fresh rows into the vector
and FTS indexes. Policy (`optimiseDue`): optimise as soon as the queue
drains in normal operation (so every save or move sweep is followed by one
cheap optimise), and every 256 writes while a bulk backlog (first indexing,
migration re-export) is still draining.

## Consequences

an author's publish is searchable within seconds; a
migration-era re-export costs one tree read and re-embeds only changed
pages. Search never blocks a mutation or a refresh response.
