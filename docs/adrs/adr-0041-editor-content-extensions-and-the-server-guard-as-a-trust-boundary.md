---
id: ADR-0041
name: Editor Content Extensions, And The Server Guard As A Trust Boundary
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0041: Editor Content Extensions, And The Server Guard As A Trust Boundary

## Context

Adding a Markdown block or inline type to the editor (RFC-0017) used to
thread through a closed, exhaustive `switch` in each of several representations
(model union, mdast-to-model parse, model-to-HTML render, DOM-to-model and
model-to-Markdown serialise, the Tiptap node), every one of which threw on an
unknown type, plus the Haskell save-time `supportedBlock` guard. Arbitrary
extensions were impossible without editing core files for each one. Separately,
ADR-0040 retained the server's save-time validation as "raw-HTML rejection plus a
supported-block subset check"; with a client-extensible, open subset that subset
check becomes the cross-language dual-implementation trap ADR-0040 itself rejected
for rendering (the Haskell recogniser cannot track arbitrary client extensions).

## Decision

(1) Introduce a content-extension registry: each extension is one
module registering handlers for the seams it needs (parse, render, serialise in
and out for both blocks and inlines, a document-level render, and remark
plugins), and the core dispatchers became fail-soft registry walks over an open
model (`CustomBlock` / `CustomInline`); the built-in subset is the always-present
fallback extension. Parse seams stay strict (an unknown mdast node throws,
preserving the raw-HTML guard); render and serialise seams fail soft. (2) Adopt
Lit for the editor's *view layer only* (the toolbar, bubble, slash menu, link
popover, and the extensions' chrome -- table controls, callouts, collapsible
toggle), while the controllers, the registry, and the Tiptap/CodeMirror adapters
stay framework-agnostic; Lit already ships via Web Awesome, so this is no new
runtime dependency. (3) Narrow the Haskell `MicroHttp.TestApp` save-time guard to
raw-HTML rejection only, dropping block-structure validation. The editor is the
authority on its own open subset; the server defends the trust boundary, not the
grammar.

## Consequences

a new editor feature is a new module plus one `registerExtension`
call, with zero edits to the core dispatchers (proven by GFM tables, GFM
admonitions, mkdocs collapsibles, and GFM footnotes, all landed this way). Raw
HTML stays uniformly rejected, so the server never trusts client Markdown to be
safe; but it no longer constrains document *structure*, so editor subset growth
no longer needs a coordinated Haskell change (the dual-implementation trap is
closed, consistent with ADR-0040/ADR-0019). The narrowing is a behaviour change --
the server now accepts Markdown the old block check rejected (e.g. an unterminated
code fence) -- covered by `MicroHttp.TestApp` tests. Each extension carries its
own per-extension golden tests (parse, render, DOM-serialise, round-trip) as the
correctness net, since the server no longer validates structure.

Refines ADR-0040: that ADR's retained validation was "raw-HTML rejection plus a
supported-block subset check"; the subset check is now removed. The raw-HTML
rejection and the browser-owned-rendering stance are unchanged.
