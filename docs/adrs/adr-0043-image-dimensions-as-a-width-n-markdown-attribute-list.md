---
id: ADR-0043
name: Image Dimensions As A `{width=N}` Markdown Attribute List
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0043: Image Dimensions As A `{width=N}` Markdown Attribute List

## Context

Images (ADR-0042, RFC-0018) needed a resize capability, which means a way
to persist a display size. Markdown has no native image-size syntax, and the
project uniformly rejects raw HTML at save time (ADR-0040/0041), so `<img width>`
is not an option -- it would reopen the trust hole that guard exists to close. A
size is only meaningful if it round-trips through the saved Markdown (visual ->
Markdown -> reload), so it must live in a Markdown representation, not in editor
state alone. Candidates: a Pandoc/`attr_list` attribute list
(`![alt](src){width=N}`), an Obsidian-style pipe in the alt text
(`![alt|N](src)`), or a query parameter on the URL handled by the serving layer.

## Decision

persist the size as a Pandoc-style attribute list immediately following
the image -- `![alt](src "title"){width=N}` -- carried on the existing image
content extension (ADR-0041). The source pipeline parses it with a small remark
transform that lifts a leading `{width=N}` off the text after an image onto the
image node and consumes that text; render emits an escaped `<img ... width="N">`;
serialise emits `{width=N}`; the DOM serialise seam reads the `width` attribute
back. The visual editor's Tiptap image node gains a `width` attribute, a drag
handle node view that commits the dragged width to it, and a post-load pass that
applies a `{width=N}` left as literal text by marked (which has no attribute-list
support) -- mirroring how the other non-CommonMark syntaxes are pre/post-processed
around marked. v1 stores width only (height auto, aspect ratio preserved) in
integer pixels; display is bounded to the editor width by CSS so an over-wide
value never overflows, while the stored value is preserved.

## Consequences

image sizing stays inside the Markdown subset and the
content-extension registry -- no raw HTML, no new server route, no
attachment-layer transcoding -- so the save-time guard and browser-owned
rendering (ADR-0040) are unchanged. The attribute list is a documented, portable
Markdown convention; the no-JavaScript raw-Markdown view shows the literal
`{width=N}` text, which is acceptable (it is raw Markdown). The pipe-in-alt
alternative was rejected (it corrupts the alt text and collides with a literal
`|`); the URL-parameter alternative was rejected (it pushes resizing into the
serving layer -- an RFC-0018 non-goal). `height`, percentage widths, and a numeric
width control alongside the drag handle are natural later extensions of the same
`{...}` syntax.

Builds on ADR-0041 (content-extension registry) and ADR-0042 (the images it sizes);
consistent with ADR-0040 (raw HTML rejected, browser-owned rendering).
