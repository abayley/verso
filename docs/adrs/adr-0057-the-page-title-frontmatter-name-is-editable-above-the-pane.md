---
id: ADR-0057
name: The Page Title (Frontmatter `name`) Is Editable Above The Pane
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0057: The Page Title (Frontmatter `name`) Is Editable Above The Pane

## Context

a page's title is its frontmatter `name`, not part of the body content.
ADR-0047 preserved frontmatter but hid it from editing entirely; there was no way
to change the title. The title is a primary, frequently-edited field and deserves
a first-class control, without exposing the rest of the frontmatter.

## Decision

surface the `name` field as a dedicated title field above the editing
pane (sized to match it): an input in the edit view, read-only text in the read
view. Editing it does a minimal-byte update of the `name:` line in the preserved
frontmatter block (`setFrontmatterName`, mirroring ADR-0049 for sidecar YAML) --
the value line is replaced (or a `name:` line inserted, or a frontmatter block
created when there is none) and every other line is kept verbatim. The change
flows through the normal save path, so the title persists with the body. The rest
of the frontmatter stays hidden and preserved.

## Consequences

`name` becomes the one editable frontmatter field; the others remain
hidden and verbatim, so ADR-0047's preservation guarantee still holds for them.
The read/write helpers (`frontmatterName`/`setFrontmatterName`) are pure and
unit-tested, including quoting of values that are not plain YAML scalars. Refines
ADR-0047 (frontmatter is preserved -- and now its title is editable).
