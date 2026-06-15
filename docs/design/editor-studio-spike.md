# Editor Studio Interaction Spike

A throwaway spike exploring the interaction model behind the deferred Studio
theme (mockup C, RFC-0015): a **selection bubble toolbar** instead of a
persistent toolbar, and a **slash command menu** for inserting blocks. The
question was feasibility, and whether it needs the long-deferred Lit adoption
for the editor shell (ADR-019 notes, `markdown-editor-spike.md`).

Code: `spike/editor-studio/` (`main.ts` + `index.html`, bundled with
`bun build`). It builds a minimal Tiptap `StarterKit` editor and adds both
interactions by hand. It is not wired into the production editor.

## What was built

- **Bubble toolbar.** On a non-empty selection (`onSelectionUpdate`), a small
  floating toolbar is positioned over the selection using
  `editor.view.coordsAtPos(from/to)` and shows Bold / Italic / Strike / Code.
  Buttons call `editor.chain().focus().toggle*()` and reflect the active marks
  via `editor.isActive(...)`.
- **Slash menu.** When the current block's text is exactly `/`
  (`$from.parent.textContent === "/"`), a menu opens at the caret
  (`coordsAtPos`) listing Heading 1/2, Bullet list, Numbered list, Quote, and
  Code block, with Up/Down/Enter/Escape keyboard navigation. Choosing a command
  deletes the `/` and applies the block command.

## Findings

- **Both interactions are feasible with what the editor already has.** No Tiptap
  menu package (`@tiptap/extension-bubble-menu` / `-floating-menu`) and no Lit
  were needed. Positioning is the same hand-rolled approach the editor already
  uses for its link editor and link-action popovers (`coordsAtPos` /
  selection rects). This is consistent with the standing decision to keep Lit
  deferred: the popover and menu state here is small and local, not the kind of
  sprawling manual DOM state that would justify a framework.
- **Bubble toolbar: verified working.** Selecting a word raises the toolbar over
  it; toggling Bold applied the mark and the `B` button showed its active state.
- **Slash menu: verified working.** Typing `/` on an empty line opened the menu
  at the caret with all six commands and keyboard navigation; choosing one
  removed the `/`.
- **Block commands need the right Tiptap call, and a clean selection.** Raw
  `setNode("heading", …)` is the wrong form in Tiptap 3 (`setHeading` /
  `toggleHeading` are correct). Even then, conversions reported success but
  no-opped when driven over a document left messy by repeated scripted edits;
  on a clean selection `toggleHeading` converted the block correctly. The
  production Studio should call the editor's existing, proven block commands
  (`applyBlockStyle` / `applyStructureStyle` in `tiptap-visual-editor.ts`)
  rather than raw `StarterKit` commands, which sidesteps this entirely.
- **Focus gating.** A real build should hide the bubble when the editor is not
  focused (`editor.isFocused`); the spike omits that guard only so the bubble
  can be exercised in a headless browser (which reports no window focus).

## Recommendation

Studio is buildable as a theme-plus-interaction without new dependencies. When
it is picked up:

- Add the bubble toolbar and slash menu to `markdown-editor-element.ts`, reusing
  the existing popover-positioning helpers and the existing block/inline command
  methods (so the commands are the proven ones, and the bubble shares the link
  popover's lifecycle).
- Keep them behind the Studio theme's chrome: Studio hides the persistent
  command bar and relies on these two surfaces; the other themes keep the bar.
  (Per RFC-0015, a deferred-Studio toolbar may instead sit below the workspace
  if that reads better.)
- Lit is still not required for this; revisit only if the popover/menu state
  later grows well beyond these two surfaces.

## Status

Spike complete and acted on. Studio shipped as an editor theme in RFC-0016
(ADR-037): the bubble toolbar and slash menu were added to
`markdown-editor-element.ts`, reusing the existing `positionOverlay` helper and
the proven `toggleInlineStyle`/`applyBlockStyle`/`toggleStructure` commands, with
no Tiptap menu package and no Lit -- as this spike recommended. This document
remains the record of why that approach was chosen. The spike build artifact
(`spike/editor-studio/bundle.js`) is gitignored; rebuild with
`bun build spike/editor-studio/main.ts --outfile spike/editor-studio/bundle.js`
and open `index.html` (or serve it) to try it.
