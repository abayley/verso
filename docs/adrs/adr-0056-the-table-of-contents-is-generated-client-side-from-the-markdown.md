---
id: ADR-0056
name: The Table Of Contents Is Generated Client-Side From The Markdown
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0056: The Table Of Contents Is Generated Client-Side From The Markdown

## Context

the editor sidebar gained a generated table of contents (a "Contents"
panel above the attachments panel). The headings could be extracted server-side
(at render/save) or client-side (in the editor). The Markdown body is already the
single client-side source of truth for every view mode (ADR-0051: marked is the
engine, the server stores-and-serves and does not render); a server-extracted TOC
would need a render path the TestApp deliberately does not have, and would drift
from the live document as the author types.

## Decision

generate the contents client-side. A pure `documentHeadings(markdown)`
scans the body for top-level ATX headings (skipping fenced code; setext and
indented headings are not listed) and the panel re-renders on every content
change, so it stays correct across the visual, source, split, and read views with
no server round-trip. The panel is shown whenever the document has at least one
heading (not only in the document tree), and sits in the right-hand sidebar above
the attachments panel; the sidebar collapses when it has nothing to show. Clicking
an entry scrolls the active pane to that heading -- the entry's index is the
heading's order in the document, matched to the n-th rendered heading element (or,
in source mode, the n-th heading line). Active-section highlighting (scrollspy) is
deferred.

## Consequences

the TOC needs no server support and cannot drift from the live
document; it is one pure function plus a panel, unit-tested on the parser. The
index-based scroll target assumes the listed (top-level) headings map one-to-one
and in order onto the rendered headings, which holds for flat documents; headings
nested inside collapsibles or list items are intentionally neither listed nor
counted. Consistent with ADR-0051 (rendering and document analysis are
browser-owned).
