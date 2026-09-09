---
id: ADR-0037
name: Studio Editor Surfaces As Hand-Rolled Popovers Over Existing Commands
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0037: Studio Editor Surfaces As Hand-Rolled Popovers Over Existing Commands

## Context

Studio (mockup C), deferred by ADR-0036/RFC-0015, is defined by two new
interactions rather than colour: a selection bubble toolbar (formatting raised
over a non-empty selection) and a slash command menu (blocks inserted by typing
`/`). The persistent command bar is removed in this look. The open question was
whether these surfaces need a Tiptap menu package or the long-deferred Lit
adoption (ADR-0019), or whether the editor's existing machinery suffices. An
interaction spike (`docs/design/editor-studio-spike.md`) showed the existing
hand-rolled popover positioning and the proven block/inline/structure commands
are enough.

## Decision

Ship Studio as a sixth visual theme (registered the same three ways as
the others: token block, dropdown entry, server allowlist) plus one bounded
behavioural preset, `themeUsesStudioSurfaces`, that in visual mode hides the command bar (a host
`markdown-editor--studio-surfaces` class, not a teardown) and activates the two
surfaces. The surfaces are visual-pane only, so source and split mode keep the
command bar (the source pane needs it); the class re-evaluates on mode change.
The bubble toolbar and slash menu are built as general editor capabilities in
`markdown-editor-element.ts`, reusing the existing `positionOverlay` helper and
the existing `toggleInlineStyle`/`applyBlockStyle`/`toggleStructure` paths, and
are only activated under Studio this round. The bubble carries a block-style
selector (Paragraph, Heading 1-3) alongside the inline controls, so an existing
line can be converted in place without the command bar; this is needed because
the bar is hidden in visual mode and the slash menu only fires on an empty `/`
block. The bubble observes a document
`selectionchange` listener and reads the DOM selection; the slash menu detects
the trigger and resolves the caret block through `posAtDOM` on the DOM caret (the
same basis as the existing commands), not ProseMirror's selection state, with
capture-phase keyboard navigation. No Tiptap menu package and no Lit are added.
The mockup's document sidebar and multi-document breadcrumb are not shipped: they
imply a backend that does not exist, so Studio carries only chrome backed by data
the editor already has (matching Workbench's precedent). The design is RFC-0016.

## Consequences

Studio is additive -- existing themes, the colour-scheme axis, and
the command bar under every other theme are unchanged; switching theme is a class
flip with no editor rebuild, so content and save state are preserved. The two
surfaces are general enough to enable under other themes later without rework.
Lit stays deferred (ADR-0019); revisit only if popover/menu state grows well
beyond these two surfaces. Anchoring detection on the DOM caret keeps the
surfaces testable under happy-dom, consistent with the existing command tests.
