---
id: ADR-0021
name: Progressively Enhance the Editor Page
status: Proposed
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0021: Progressively Enhance the Editor Page

## Context

The editor page is currently an empty shell that requires JavaScript
to fetch and submit the document, which relegates the server to a minimal API
role and leaves script-less browsers with an unusable page. The project wants
MicroHttp to stay a reasonably general-purpose server for server-rendered
htmx applications, with rich client components as islands of interactivity
rather than the default architecture.

## Decision

Serve `GET /documents/:id/edit` as a complete, working Markdown
form: a `<textarea name="markdown">` with the document content inside the
`<markdown-editor>` element. Capable browsers upgrade the page in place: the
element adopts the textarea content, participates in form submission through
`ElementInternals`, and provides the rich editing experience. The post
handler answers both ordinary form posts (post-redirect-get, full-page
validation re-render) and htmx posts (status fragments). The design is
RFC-0001.

## Consequences

The server renders meaningful HTML for every client and owns
document delivery again; the separate document fetch and the hidden
`markdown` input are removed. The raw-Markdown textarea keeps the ADR-0019
contract: the server still does not parse or render Markdown. Handlers must
branch on the `hx-request` header, and the browser smoke coverage must
include a JavaScript-disabled pass.
