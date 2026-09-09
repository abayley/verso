---
id: ADR-0050
name: Reading Is The Default; A Page GET Renders Read-Only, Raw Markdown Moves Behind ?raw
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0020]
---

# ADR-0050: Reading Is The Default; A Page GET Renders Read-Only, Raw Markdown Moves Behind ?raw

> Status: Accepted (realised by RFC-0020).

## Context

ADR-0045 set the tree request model as a plain `GET /documents/<path>.md`
serving the raw Markdown and `?edit` opening the editor. Following a link to a
page therefore showed raw Markdown source, which is poor for reading. The owner
wants reading -- rendered -- to be the default browsing experience, to match the
editor's own rendering, and to carry the same side panels (RFC-0019, and later a
navigation tree and a table of contents) and the visual/Markdown/split view
switcher.

## Decision

a plain `GET` on a tree Markdown page serves a read-only rendered view;
`?edit` serves the editable editor (unchanged); `?raw` serves the raw Markdown
verbatim as `text/markdown` (the former plain-`GET` behaviour, moved behind the
selector); `POST` still saves. The read view reuses the editor shell rather than a
second renderer: an opt-in `data-readonly` attribute (absent = editable, so flat
mode and `?edit` are unchanged) disables content editing and the server omits the
autosave form, so there is no write path. The top bar (presentation -- view
switcher, width, theme, document name) stays; the bottom bar (editing controls)
plus the floating editing affordances (bubble toolbar, slash menu, table/link
controls, upload) are hidden, and the attachments panel degrades to a read-only
list. Reading opens in visual mode (the view mode is not persisted and defaults to
visual); switching to Markdown/split while reading is session-only. A missing page
returns `404` for both `GET` and `?raw`; seeding a starter document stays an
`?edit`-only affordance.

## Consequences

a plain `GET` of a page now returns an HTML page, not raw text --
a deliberate breaking change for tooling and diffs, which use `?raw`. Reading and
editing render identically per view because they are the same shell (parity is
"read mirrors edit within each mode", not "the visual and split renderers agree" --
that pre-existing divergence is untouched). Rendering stays browser-owned (no
server-side Markdown renderer), and a no-JavaScript `GET` degrades to the embedded
raw Markdown, so ADR-0040 holds. Amends ADR-0045's request model (`GET` reads
rendered; `?raw` is raw; `?edit` edits; `POST` saves); the document id and URL
scheme are otherwise unchanged. Builds on ADR-0040 (browser-owned rendering),
ADR-0047 (frontmatter hidden), and ADR-0048 (raw HTML inert).
