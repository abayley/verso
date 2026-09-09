---
id: ADR-0054
name: Collapsibles Render As Native `<details>`/`<summary>` (The Element, Not The Source)
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0054: Collapsibles Render As Native `<details>`/`<summary>` (The Element, Not The Source)

## Context

RFC-0017 renders a collapsible as a hand-rolled Tiptap node -- a `<div>`
with a `data-open` attribute and a click-to-toggle title bar -- explicitly to
avoid Tiptap's paid `Details` Pro extension. RFC-0017 separately rejected
`<details>` *as a source syntax* (authoring raw `<details>` HTML in the Markdown
would reopen the raw-HTML trust hole ADR-0040 closed); collapsibles use the mkdocs
`???` syntax. Those two are distinct: the source decision did not govern the
rendered DOM element, and the `<div>` is incidental, not principled. `<details>`
/`<summary>` is the semantic disclosure element and brings native keyboard
toggling and screen-reader support for free.

## Decision

render the collapsible node as
`<details class="markdown-collapsible markdown-collapsible-<kind>"><summary
class="markdown-collapsible-title" contenteditable="false">title</summary><div
class="markdown-collapsible-body">body</div></details>`. The open/closed state
stays in the ProseMirror document model (it round-trips to `???` versus `???+`
and must be undoable); the node view intercepts the `<summary>` toggle and routes
it through a transaction (as the `<div>` click handler already did), keeping the
`<details open>` attribute reflecting the model rather than letting the browser
mutate it directly. The Markdown source is unchanged -- still mkdocs `???`; the
editor *renders* `<details>` but never *accepts* raw `<details>` as input, so the
raw-HTML ban (ADR-0040/0041) and RFC-0017's source decision are untouched. The
DOM-serialise seam reads `<details.markdown-collapsible>` back to the model.

## Consequences

collapsibles become semantic and accessible (native disclosure
marker, focusable summary, Enter/Space toggle, AT support), and the browser hides
the closed body natively so the custom open/close CSS is no longer needed. The
editor's DOM contract for a collapsible changes from `<div>` to `<details>`
(parse and serialise seams move together). Refines RFC-0017 (the rendered element
only); the `???` source syntax, the raw-HTML ban, and the no-Pro-dependency
constraint all stand. Implemented by RFC-0025.
