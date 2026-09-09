---
id: ADR-0055
name: Theme Set Revision -- Retire Herbarium, Differentiate Studio And Workbench
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0055: Theme Set Revision -- Retire Herbarium, Differentiate Studio And Workbench

## Context

ADR-0036/RFC-0015 shipped the visual themes as a mostly-CSS axis: each
theme is a block of `--markdown-editor-*` token overrides, and the content
surface typography (`Georgia ... serif`) and page layout are shared by every
theme. In practice the colour-only themes read as near-identical -- Paper,
Herbarium, and Workbench differ only in palette plus minor chrome. Herbarium (a
ruled-paper journal) added a decorative background but no distinct interaction or
type, so it earned its keep the least. Studio (ADR-0037) and Workbench were meant
to be structurally distinct (a Notion-style slash/bubble surface; an IDE
workbench) but both inherited the shared serif and most of the shared layout, so
neither resembled its source mockup
(`docs/mockups/markdown-editor-redesign-c-workspace-studio.html`,
`...-b-dark-workbench.html`).

## Decision

(1) retire Herbarium entirely -- remove its token blocks, the ruled
background, and its entry from the three registration points (the CSS, the editor
dropdown, the server allowlist `knownEditorThemes`); a stored or configured
`herbarium` now falls back to Paper through the existing validation. (2) Let a
theme override the surface typography, not only colour: Studio switches the
content font to a sans-serif stack to match its Notion lineage, and gains a
caret placeholder hint ("Type / for commands") on empty blocks so the slash menu
is discoverable without a persistent toolbar. (3) Give Workbench the IDE layout
its mockup implies. The editor's shared DOM is regrouped so the document name is
a sibling of the presentation controls (not nested), and each region -- controls,
name, formatting bar, panes, status -- can be placed independently. Workbench
then makes the host a CSS grid forming a viewport-flush app frame: a presentation
rail down the left (view mode, width, theme, colour scheme -- the existing
controls stacked, a wider text rail, not the mockup's decorative icon strip), the
file tab and the formatting toolbar across the top, the panes filling the centre
(the only region that scrolls), and a full-width accent status bar along the
bottom carrying a format label, caret position, and word count. Content drops the
shared serif for a sans stack. The default themes keep the shared vertical-stack
layout unchanged (the grid is gated on the theme). The mockup's decorative
icon-only rail and caret-tracked preview are still excluded: the rail holds real
controls rather than feature-less icons, and caret-sync is feature work, not
styling.

## Consequences

the theme set is Paper, Aurora, Blueprint, Workbench, Studio.
Typography and full layout join colour and bounded presets as themable axes: a
theme may now reflow the shared regions into a different frame (Workbench's IDE
grid) without forking the editor, because the regions are addressable DOM placed
by CSS per theme. The caret readout comes from the source pane (the only pane
with a line/column notion) and is hidden when no source pane is shown. Refines
ADR-0036 and ADR-0037 (the theme set and Studio's surfaces); the
registration-in-three-places contract and the pre-paint allowlist bootstrap
stand.
