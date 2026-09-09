---
id: ADR-0039
name: Editor Edit Page As Progressive Enhancement
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0039: Editor Edit Page As Progressive Enhancement

## Context

The edit page was a script-only shell -- it rendered an htmx form, the
`<markdown-editor>` fetched the document through a `src` attribute, and the
Markdown reached the server through a hidden input populated on the htmx
`configRequest` event. A browser without JavaScript got a blank page. RFC-0001
made the page work without scripting and upgrade in place.

## Decision

`GET /documents/:id/edit` server-renders a real form
(`action`/`method` plus the htmx attributes) containing a
`<textarea name="markdown">` with the current document inside the
`<markdown-editor>` element, and a `<noscript>` submit button. `POST
/documents/:id` answers both modes from one route, branching on the `hx-request`
header: htmx keeps the status-fragment behaviour; an ordinary post follows
post-redirect-get (`303` to the edit page) on success and re-renders the edit
page with the validation message and the escaped submission on failure. Form
posts have their CRLF newlines normalised to LF so the document contract stays
line-feed only. On upgrade the element adopts the textarea (disabling and hiding
it but keeping it in the DOM), becomes a form-associated custom element
(`static formAssociated`, `attachInternals` guarded for runtimes without
support) and keeps its value current with `setFormValue`; the displayed document
name comes from an explicit `data-document` attribute. The hidden input is
removed; the `configRequest` hook is kept only to set the htmx request parameter
(a robust complement to `ElementInternals`, since `FormData` already carries the
element's value). The design is RFC-0001.

## Consequences

the editor works with JavaScript disabled (textarea form, ordinary
post, redirect) and is unchanged when enhanced (autosave, save states,
validation, shortcuts). One route serves both submission modes; one value source
(the element, or the textarea without scripting) avoids the duplicate-`markdown`
hazard that blocked a literal phase split, so the page-structure and element
changes landed together. `src` is no longer used on the edit page but remains
supported for embedding. The textarea fallback page carries no design
investment beyond legibility (ADR-0019/ADR-0022 stand: no server-side Markdown
rendering, no templating engine).
