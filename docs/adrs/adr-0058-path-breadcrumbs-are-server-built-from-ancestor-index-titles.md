---
id: ADR-0058
name: Path Breadcrumbs Are Server-Built From Ancestor Index Titles
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0058: Path Breadcrumbs Are Server-Built From Ancestor Index Titles

## Context

the editor showed the document filename in the top bar. A breadcrumb
trail of the path is more useful, but each crumb's label should be the ancestor
folder's *title* (its `index.md` frontmatter `name`), not the raw folder segment,
and each should link to that folder's page. Unlike the contents panel (ADR-0056,
client-side from the open document), the ancestor titles live in *other* files the
client never loads -- only the server can read them.

## Decision

build the trail server-side. For a document path the server walks its
ancestor folders, reads each `index.md`'s frontmatter title, and embeds the trail
as `data-breadcrumbs` JSON (`[{label, href}]`, href omitted for the current page)
on the editor element; the client renders it in place of the filename, each
ancestor a link and the current page plain text. A folder index page contributes
its folder as the current crumb rather than also linking it. Crumbs link to the
explicit `index.md` document (`/documents/<dir>/index.md`), because a bare
directory URL is not itself routable. A folder with no `index.md` title falls back
to a humanised segment (the root to "Cello"). The current page's own title comes
from the document already being served, so it costs no extra read.

## Consequences

breadcrumbs need the server (a few `index.md` reads per page load,
bounded by tree depth) -- the opposite split from the contents panel, because the
data source is other files, not the open document. The pure parts (the linked
ancestor folders for a path; the frontmatter-title parser) are unit-tested; flat
(non-tree) documents get no trail and fall back to the filename. Reuses the
embed-JSON-then-render-client-side pattern of the attachments panel (RFC-0019).
