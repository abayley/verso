---
id: ADR-0019
name: Keep Markdown Parsing and Rendering in the Editor
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0019: Keep Markdown Parsing and Rendering in the Editor

## Context

The Markdown editor spike proved that htmx and web components can use a
plain Markdown field as the HTTP contract. Phase Three also showed that growing
parallel browser and server Markdown parsers creates duplication quickly. The
server does not need to own rich Markdown parsing to satisfy the core MicroHttp
goal; it can store and serve Markdown documents while the editor owns parsing,
rendering, validation, and preview behaviour.

## Decision

Keep the MicroHttp server minimal for Markdown documents. The server
stores submitted Markdown and serves Markdown documents or static editor assets.
The editor owns Markdown parsing, rendering, preview, and visual editing. remark
and mdast are a development/reference contract for fixtures and expected
Markdown behaviour, not a production server runtime dependency.

## Consequences

Server-side Markdown parsing should not grow beyond narrow spike
support unless a later ADR changes ownership. The current TestApp renderer is
spike evidence and should be treated as replaceable. Future editor work should
adapt browser-side libraries, such as remark or ProseMirror/Tiptap, behind the
`<markdown-editor>` custom element while keeping the HTTP/storage contract as
Markdown text.
