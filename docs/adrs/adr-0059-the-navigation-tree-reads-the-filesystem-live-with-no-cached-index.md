---
id: ADR-0059
name: The Navigation Tree Reads the Filesystem Live, With No Cached Index
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0026]
---

# ADR-0059: The Navigation Tree Reads the Filesystem Live, With No Cached Index

> Status: Accepted (RFC-0026).

## Context

the editor needs a left-hand navigation tree over the document tree.
The reference tree is large (~3,900 pages, ~2,200 directories, depth 10) and is
the source of truth, edited out-of-band (directly, and by an external
move-utility that reconciles links and sidecar metadata). A materialised index
(in-memory, persisted, incrementally maintained on save/CRUD) was considered: it
would give whole-tree search and instant expansion, but it is a *cache* of a
filesystem that changes behind the server's back, so it adds drift, a
persistence/reconciliation story, and incremental-maintenance complexity. On
local storage at this tree size the performance gap over a live read is below the
perception threshold and is dwarfed by the editor's own JavaScript startup, so
the index would buy search, not speed.

## Decision

feed the tree from one contract, `GET /tree/*path`, that lists a
folder's immediate children by reading the filesystem live on each request. The
client fetches lazily on expand and caches fetched subtrees for the session, with
an explicit refresh; the open page's ancestor spine is embedded so it opens
pre-expanded without load-time fetches. No server-side index is built or
persisted. The choice is forward-compatible: an index, if ever wanted for search,
slots in behind the same endpoint as its own RFC, wasting none of this work.

## Consequences

the tree is always correct -- out-of-band changes appear on the
next read, with no drift or reconciliation, and create/edit/delete need no index
maintenance. The cost accepted is no whole-tree search (a lazy tree cannot search
folders it has not fetched; a future server-side search endpoint could add it)
and a small per-expand/per-load filesystem read cost. Section labels reuse the
ancestor-index-title reading of ADR-0058, and a section's `index.md` is folded
into the section node rather than shown as a child (extends ADR-0058).
