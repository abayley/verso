---
id: ADR-0046
name: Tree Uploads Land In The Page's Peer `assets/` With Meaningful Names
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0046: Tree Uploads Land In The Page's Peer `assets/` With Meaningful Names

## Context

In tree mode (ADR-0045) an upload must fit the tree's layout: the file
belongs in the editing page's peer `assets/` folder and is referenced
page-relative (`assets/<name>`), not in the central content-addressed store
(ADR-0042) with an absolute `/attachments/<hash>/<name>` URL. The owner wanted
meaningful filenames with real extensions (the content hash hides the type) while
keeping the de-duplication the hashed store gave.

## Decision

a tree upload is `POST /documents/<path>.md?asset` with the file as the
raw body and the original name in `X-Attachment-Filename`. The server writes it
into the document's peer `assets/` folder under a sanitised, meaningful filename
with its real extension, de-duplicating within that folder (identical bytes reuse
the existing file) and suffixing on a name clash with different content
(`diagram.png` -> `diagram-2.png`), gated by the same type allow-list as the
central store (415 otherwise). It returns `{"url":"assets/<name>"}`, a
page-relative reference the editor inserts. A `?asset` POST is dispatched to the
upload; a plain POST still saves the document.

## Consequences

assets sit beside their page exactly as the tree expects, with
human-readable, typed filenames, and dedup is preserved -- now local to each
folder (cross-page duplication is inherent to the peer-assets layout and
accepted). Naming meaningfully (rather than by hash) needs collision handling,
which the within-folder suffix provides; the trade-off versus the central store's
collision-free hashing is intentional, scoped to tree mode. The flat mode keeps
the content-addressed `/attachments` store (ADR-0042). Reuses the filename
sanitiser and allow-list from `MicroHttp.Attachment`.
