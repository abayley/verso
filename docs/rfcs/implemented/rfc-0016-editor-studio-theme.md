---
id: RFC-0016
name: Editor Studio Theme
status: Implemented
owners:
    - alistair
created: 2026-06-15
updated: 2026-06-15
supersedes: []
superseded_by: null
---

# Editor Studio Theme

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-15       |
| Started   | 2026-06-15 16:02 |
| Completed | 2026-06-15 17:51 |

## Summary

Ship Studio (mockup C, "Workspace Studio"), the visual theme RFC-0015 deferred
because its defining behaviour exceeds CSS. Studio is a calm Notion-style paper
look that removes the persistent command bar and moves formatting into two
floating surfaces: a **selection bubble toolbar** raised over a non-empty visual
selection, and a **slash command menu** opened by typing `/` on an empty block.
Both surfaces drive the editor's existing, proven block/inline/structure
commands and reuse the existing overlay-positioning helper, so no Tiptap menu
package and no Lit are introduced (confirmed by the spike,
`docs/design/editor-studio-spike.md`). Studio registers like any other theme
(token block, dropdown entry, server allowlist) plus a small bounded preset that
hides the command bar and activates the two surfaces.

## Context

RFC-0015 built a `data-editor-theme` axis and shipped five themes (Paper,
Aurora, Blueprint, Herbarium, Workbench), explicitly deferring Studio: its
bubble toolbar and slash menu are genuinely new interactions, not CSS, so it was
left out rather than shipped half-formed. RFC-0015 reserved a "toolbar
placement" preset for Studio and noted its toolbar "may sit below the workspace
chrome if placing it inside proves awkward".

The interaction spike (commit `18510ca`, `docs/design/editor-studio-spike.md`)
then proved both surfaces are feasible over the editor's existing Tiptap and
hand-rolled popover machinery, with no new dependency. Its recommendation: add
the bubble toolbar and slash menu to `markdown-editor-element.ts`, reusing the
existing popover-positioning helper and the existing command methods (so the
commands are the proven ones), gated behind Studio's chrome. This RFC implements
that recommendation.

Scope decisions taken with the user before authoring:

- **Honest minimal chrome.** Studio ships the paper token set, the two
  interaction surfaces, a hidden command bar, and only chrome backed by data the
  editor already has. The mockup's document sidebar and multi-document
  breadcrumb are *not* shipped: they imply a `GET /documents/:id` backend that
  does not exist, and Workbench set the precedent of omitting synthetic chrome.
- **Interactions built general, activated under Studio.** The bubble toolbar and
  slash menu are implemented as editor capabilities (reusing existing commands),
  but are only switched on when the active theme is Studio (which hides the
  command bar). Other themes keep the persistent bar, per RFC-0015.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- Studio registered as a sixth visual theme through the existing three sync
  points (CSS token block, `visualThemes`, `knownEditorThemes`) plus its bounded
  preset.
- A bubble toolbar over a non-empty visual selection offering a block-style
  selector (Paragraph, Heading 1-3, via `applyBlockStyle`) so an existing line can
  be converted in place, plus the editor's existing inline commands (bold,
  italic, strike, code, link), reflecting active marks and the current block type,
  driving the existing `toggleInlineStyle`/`applyBlockStyle` paths.
- A slash command menu opened by `/` on an empty visual block, offering the
  editor's existing block and structure commands (headings, lists, quote, code
  block), with Up/Down/Enter/Escape navigation, that removes the `/` and applies
  the chosen command via the existing `applyBlockStyle` / `toggleStructure`
  paths.
- Under Studio the persistent command bar is hidden and the two surfaces are
  active; under every other theme the command bar shows and the surfaces stay
  off. Switching theme at runtime flips this without reload.
- Reuse: the existing `positionOverlay` helper for placement; no Tiptap menu
  package; no Lit.
- Safe fallback preserved: an unknown/invalid stored or configured theme still
  resolves to Paper (unchanged from RFC-0015).

## Non-Goals

- A document sidebar or multi-document navigation, and the `GET /documents/:id`
  backend it implies. The sidebar in mockup C is not shipped.
- A synthetic breadcrumb beyond data the editor already holds (document name,
  save state). A "Documents / Home" trail of non-existent documents is not
  shipped.
- Bubble toolbar / slash menu in the *source* (CodeMirror) pane. The surfaces are
  visual-pane only. Because they replace the command bar, the bar is hidden only
  in visual mode under Studio; in source and split mode the command bar stays
  (the source pane needs it), so those modes keep their usual controls.
- Exposing the bubble/slash surfaces under non-Studio themes in this round. The
  implementation is general enough to allow it later, but no other theme turns
  them on now.
- New Markdown features or serialisation changes; the surfaces only invoke
  commands the editor already ships.
- Lit adoption; revisit only if popover/menu state later grows well beyond these
  two surfaces.

## Proposal

### Theme registration

Studio is registered exactly like the existing themes:

- `static/editor/markdown-editor.css`: a `:root[data-editor-theme="studio"]`
  token block and a `…studio.wa-dark` block (the Notion paper palette, light and
  dark), plus a scoped structural layer for chrome and for hiding the command
  bar.
- `visualThemes` (TS, `markdown-editor-element.ts`): `{ value: "studio", label:
  "Studio" }`, appended after Workbench. `VisualTheme` gains the `"studio"`
  member.
- `knownEditorThemes` (Haskell, `MicroHttp.TestApp`): `"studio"` appended. The
  pre-paint bootstrap allowlist is already derived from this list, so no separate
  change is needed there.

### The Studio preset

RFC-0015 models layout-bearing themes as a small fixed preset set. Studio adds
one bounded behavioural preset, declared as a predicate alongside the existing
`themeDefaultMode`:

- `themeUsesStudioSurfaces(theme): boolean` -> true only for `"studio"`.

When true *and the editor is in visual mode*, the element:

- hides the persistent command bar (`markdown-editor__toolbar--commands`), and
- activates the bubble toolbar and slash menu.

The surfaces are visual-pane only, so the command bar is hidden only in visual
mode; in source and split mode it stays, because the source pane has no bubble or
slash to replace it. This re-evaluates on every mode change as well as on theme
change.

These are defaults consistent with RFC-0015's "presets are defaults, not locks":
in visual mode the command bar is *hidden* under Studio because the two surfaces
replace it. Mode, colour scheme, and theme remain freely switchable; leaving
Studio (or switching to source/split) restores the command bar.

The command bar is hidden by toggling a host-level class
(`markdown-editor--studio-surfaces`) rather than by removing the element, so
switching themes or modes is a class flip with no teardown/rebuild and no loss of
save-button or form-submission wiring. CSS hides `…__toolbar--commands` under
that class.

### The two surfaces

Both are created once during `initialise()` (like the link editor and link
actions), appended to the host, and hidden by default. Both are positioned with
the existing `positionOverlay(overlay, anchorRect)` helper, which already flips
above/below the anchor and clamps within the host.

**Bubble toolbar.** A small floating toolbar holding a block-style selector
(Paragraph, Heading 1-3) on the left followed by the existing inline controls
(bold, italic, strike, code, link). It is shown when, in the visual pane under
Studio, the editor is focused and the selection is non-empty; hidden otherwise.
The block selector mirrors the command bar's block dropdown and reuses
`applyBlockStyle`, so a selected line can be converted between paragraph and
heading in place; its label reflects the current block type. The inline buttons
reuse the element's existing `toggleInlineStyle(style)` (and the link flow's
`showLinkEditor`/visual link path), so the commands are the same proven ones the
command bar uses. Active marks are reflected on the buttons. Positioned above the
selection rect.

**Slash menu.** A floating list of the existing block and structure commands:
Heading 1/2/3 (`applyBlockStyle`), Bullet list, Numbered list, Quote, Code block
(`toggleStructure`). Shown when, in the visual pane under Studio, the selection
is empty and the current block's text is exactly `/`. Up/Down move the
highlight, Enter runs the highlighted command, Escape closes. Choosing a command
deletes the `/` then applies the command. Positioned below the caret.

### Hooks added to `TiptapVisualEditor`

The element orchestrates both surfaces but needs to observe the Tiptap editor.
The wrapper gains a narrow, read-mostly surface (no ProseMirror types leak to the
caller beyond `DOMRect`):

- an `onSelectionChange` constructor callback, fired from Tiptap's
  `onSelectionUpdate`/`onTransaction`, so the element can refresh both surfaces;
- `selectionScreenRect(): DOMRect | null` -- viewport rect spanning the current
  non-empty selection, else null (for bubble anchoring);
- `isFocused(): boolean` -- to gate the bubble on editor focus;
- `slashCaretRect(): DOMRect | null` -- caret viewport rect when the current
  block is exactly `/` with an empty selection, else null (for slash anchoring
  and detection);
- `isInlineActive(style): boolean` -- to reflect bubble button active state;
- `deleteSlashTrigger(): void` -- removes the leading `/` of the current block
  before a slash command runs.

These mirror what the spike used (`coordsAtPos`, `$from.parent.textContent`,
`isActive`, `deleteRange`) but keep ProseMirror confined to the wrapper.

### Dismissal and lifecycle

The bubble follows selection: it re-evaluates on every `onSelectionChange` and on
blur, and hides when the selection empties or focus leaves. The slash menu closes
on Escape, on running a command, and whenever `slashCaretRect()` stops matching.
Keyboard navigation for the slash menu is a capture-phase `keydown` handler on the
host, installed only while the menu is open (mirroring the existing pointerdown
dismissal pattern for the link editor), so it intercepts Up/Down/Enter/Escape
before ProseMirror.

## Alternatives Considered

- **Ship the full mockup (sidebar + breadcrumb).** Rejected for this round: the
  sidebar implies a multi-document backend that does not exist, and dead
  decorative chrome misrepresents capability (the Workbench precedent omitted
  synthetic fields).
- **Bubble/slash as a Tiptap extension package**
  (`@tiptap/extension-bubble-menu` / `-floating-menu`). Rejected: the spike
  showed the existing hand-rolled positioning is sufficient and consistent with
  the link popovers; adding packages for two small surfaces is unjustified.
- **Adopt Lit for the editor shell now.** Rejected: state here is small and local
  (two popovers), the standing decision keeps Lit deferred (ADR-019), and the
  spike confirmed it is not needed.
- **Remove the command bar element under Studio instead of hiding it.** Rejected:
  hiding via a class avoids tearing down save-button and form-submission wiring
  and makes theme switching a cheap class flip.
- **Make bubble/slash global, with Studio merely hiding the bar.** Partially
  adopted: built general, but only Studio activates them this round, per the
  scope decision; other themes keep the bar and the surfaces off.

## Security Impact

- Client CSS/JS plus one new entry in the existing server theme allowlist. The
  pre-paint bootstrap and config default still set `data-editor-theme` only from
  the validated `knownEditorThemes` allowlist; `"studio"` is added to that list,
  so no raw string reaches the attribute.
- The surfaces invoke only existing editor commands; no new input is sent to the
  server, and link insertion still flows through the existing link editor.

## Reliability Impact

- An unknown/invalid stored or configured theme still resolves to Paper
  (unchanged). If Studio's preset logic fails, the worst case is the command bar
  showing alongside an inactive surface; the editor never renders unusable.
- The surfaces are created once and toggled by class/visibility; theme switching
  does not rebuild the editor, so no content or save-state is lost.
- Positioning reuses the existing clamped helper, so a surface cannot escape the
  host bounds.

## Compatibility Impact

- Editor frontend plus one server allowlist entry. Adds the `studio` token block
  and structural layer to `markdown-editor.css`, the `studio` entries in
  `visualThemes`/`VisualTheme`/`knownEditorThemes`, the two surfaces and the
  preset logic in `markdown-editor-element.ts`, and the narrow observation hooks
  on `TiptapVisualEditor`.
- Additive: existing themes, the colour-scheme axis, the command bar under
  non-Studio themes, and all existing command paths are unchanged. The new
  `TiptapVisualEditor` constructor callback is optional.

## Testing and Quality Gates

- `make check` stays green (includes `editor-check`: TS typecheck, lint, format,
  vitest, bundle).
- `MicroHttp.TestApp` test: `"studio"` is an accepted `editor_theme` and survives
  `safeEditorTheme`; an unknown value still falls back to `paper`.
- Behaviour tests (vitest + happy-dom), added once the interaction stabilises
  (per `AGENTS.md`):
  - Under Studio in visual mode the command bar is suppressed; under Paper it is
    visible; in Studio source and split mode it is kept; switching theme or mode
    at runtime flips this.
  - Bubble toolbar: a non-empty visual selection under Studio shows the bubble;
    clicking Bold applies `**` to the serialised Markdown; the bubble hides when
    the selection empties. (Position is not asserted.)
  - Slash menu: typing `/` on an empty block under Studio opens the menu;
    choosing Heading 1 removes the `/` and produces an `#` heading; choosing
    Bullet list produces a list; Escape closes it. (Position is not asserted.)
  - The surfaces stay inactive under a non-Studio theme.
- No tests asserting colours, gradients, spacing, or surface coordinates
  (`AGENTS.md`).

## Rollout Plan

1. Phase one: registration and the visual shell (browser-first, no behaviour
   tests yet).
   - [x] `studio` token block (light + dark) and structural layer in
         `markdown-editor.css`; `studio` in `visualThemes`/`VisualTheme` and in
         `knownEditorThemes`; `MicroHttp.TestApp` test for the allowlist.
   - [x] `themeUsesStudioSurfaces` preset and the `markdown-editor--studio-surfaces`
         host class that hides the command bar in visual mode only (kept in
         source/split, since the surfaces are visual-pane only). Verified in the
         running app: Studio hides the bar in visual mode and keeps it in
         Markdown/Split; per-mode behaviour tests added.
2. Phase two: the bubble toolbar.
   - [x] `TiptapVisualEditor.isInlineActive` for bubble active state. (The bubble
         is driven from a document `selectionchange` listener reading the DOM
         selection rather than a wrapper `onSelectionChange` callback -- a local
         refinement: it avoids ProseMirror selection-sync flakiness under
         happy-dom and keeps positioning to a DOM `Range`. See Open Questions.)
   - [x] Bubble surface wired to existing inline commands and the link flow,
         gated to Studio + visual pane + non-empty selection inside the surface.
   - [x] Behaviour tests: bubble visibility, that Bold applies to Markdown, hide
         on collapse, and inactive under a non-Studio theme. Verified in the app.
3. Phase three: the slash menu.
   - [x] `TiptapVisualEditor` hooks (`isSlashTrigger`, `slashCaretRect`,
         `deleteSlashTrigger`), anchored on the DOM caret via `posAtDOM` (same
         basis as the existing command path) rather than ProseMirror's selection
         state, so detection is correct and testable under happy-dom.
   - [x] Slash surface wired to existing block/structure commands, with
         capture-phase keyboard navigation; gated to Studio + visual pane +
         empty `/` block.
   - [x] Behaviour tests: slash open, Heading 1 and Bullet list application,
         Escape close, and surfaces inactive under a non-Studio theme. Verified
         in the app, including ArrowDown/Enter navigation.
4. Phase four: document and close.
   - [x] ADR-037 for the Studio interaction surfaces; updated the spike doc
         status; marked this RFC Completed.
   - [x] `make check` green; verified the full flow in the running app (theme
         switch, bubble Bold, slash Heading/Bullet, keyboard nav, Escape).

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or RFC-0015 does not cover, stop
  changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- None outstanding at authoring. The chrome scope (honest minimal) and the
  interaction scope (built general, Studio-only activation) were settled with the
  user before authoring.

Resolved during implementation (2026-06-15):

- The bubble toolbar observes selection via a document `selectionchange` listener
  (reading the DOM selection and positioning from a `Range`) instead of the
  `onSelectionChange` wrapper callback the Proposal sketched. This is a local,
  reversible implementation choice with the same external contract: it is more
  testable under happy-dom (no ProseMirror selection sync needed) and reuses the
  existing `positionOverlay` helper. The wrapper still exposes `isInlineActive`
  for button state. The slash menu (phase three) may add the narrow PM-backed
  hooks (`slashCaretRect`, `deleteSlashTrigger`) the Proposal named.
