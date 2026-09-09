---
id: ADR-0045
name: Document-Tree Mode Serves And Edits A Filesystem Tree In Place
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0045: Document-Tree Mode Serves And Edits A Filesystem Tree In Place

## Context

Beyond the flat single-document store (ADR-0014), the editor needs to
serve and edit an existing MkDocs-style documentation tree on the filesystem:
nested section folders of `.md` pages, each with a peer `assets/` folder, and
page-relative image links (`![](assets/x.png)`). Read and write the real tree
directly (versioning is a later concern). The hard parts are document identity
for nested paths and -- the crux -- making a page's relative `assets/...` links
resolve to the real files without rewriting them.

## Decision

add a tree mode, selected by a `document_tree_root` config key (the
flat store stays the default). The whole tree is reachable under `/documents/` as
resources whose URL mirrors their filesystem path: `GET /documents/<path>.md`
serves the raw Markdown, `POST /documents/<path>.md` saves it, and every other
tree file (images, attachments) is served statically and path-safely (reusing
`Static.resolveStaticPath`, ADR-0030/0034). The editor opens at the document's own
URL with a `?edit` flag (`/documents/<path>.md?edit`). The `?edit` view-selector
is what makes relative assets resolve for free: because the editor page lives at
the file's own path, the browser resolves `assets/x.png` to
`/documents/<dir>/assets/x.png` -- the real asset's static URL -- with no
`<base>` tag and no link rewriting. (A separate `/edit/...` prefix would move the
page's base path and break that.) The document id is the tree-relative path
including `.md`.

## Consequences

this is the most resource-oriented shape -- documents and assets
each have a canonical URL that mirrors the tree, GET reads and POST writes, and
relative links resolve to the resources they name. It reuses the proven static
serving (zero-copy, path-safe) for everything but the edit page and save. The
router's terminal-only `*wildcard` makes a `/documents/<path>/edit` suffix
impractical, which the `?edit` query sidesteps (and which the relative-asset
resolution wants anyway). Writes go straight to the user's files; document
versioning and an undo/safety net are deferred and called out as follow-ups. The
flat mode and its routes are unchanged.
