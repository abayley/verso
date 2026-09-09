---
id: ADR-0047
name: Frontmatter Is Preserved And Hidden From Editing
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0047: Frontmatter Is Preserved And Hidden From Editing

## Context

Tree documents carry YAML frontmatter (a `name`, sidecar `meta` paths, a
`cover-image`). The editor had no frontmatter handling: remark parsed a leading
`---...---` as a thematic break plus literal text, so it rendered wrong and would
be corrupted on save. The frontmatter is metadata the author should not edit, but
it must survive a round-trip verbatim.

## Decision

split the frontmatter off the document on load (and on `setMarkdown`)
and stash it verbatim, so the editors only ever receive the body and the author
can neither see nor edit it (in any mode). Re-attach it unchanged when the
document is persisted, via a `documentMarkdown()` used for the form value
(`ElementInternals`) and the htmx autosave parameter; the editor's `toMarkdown()`
stays body-only, since it drives the preview, pane sync, and mode-switch
validation. A leading `---` with no closing delimiter is a thematic break, not
frontmatter.

## Consequences

frontmatter round-trips byte-for-byte while the editing surface
shows only the body, and the body is re-serialised canonically as before. Hiding
it (rather than showing it read-only) is the simplest faithful option and what
the owner chose; a read-only display remains a later possibility. The split is at
the editor boundary, so it is editor-wide, not tree-specific. Consistent with
ADR-0040 (browser-owned rendering): no server-side frontmatter handling is added.
