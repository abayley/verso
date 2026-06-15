# Markdown Editor Redesign Mockups

This document records alternative visual designs for the TestApp Markdown
editor page at `/documents/home/edit`. The first round (designs A to H) was
produced on 2026-06-10 as static HTML files in this directory: A to D are
practical directions, E to H deliberately extreme style explorations. A second
round (designs I to M) was added on 2026-06-15 -- five further directions, each
distinct from the others and from the first round. They are design references
only; they are not served by the TestApp and are not part of the editor build.

Each mockup keeps the current editor functionality: visual, Markdown source,
and split view modes, block styles, inline marks (bold, italic, strikethrough,
inline code, link), structure controls (lists, blockquote, code block,
horizontal rule), save state, and theme switching. Only the visual treatment
and control placement change.

The mockup files use the Tabler icon webfont from a CDN, so icons need network
access to render. Open the files directly in a browser.

## Markdown Editor Current Design Observations

The current page is the default Web Awesome look: one dense, full-width icon
toolbar over a borderless white surface. All seventeen or so controls carry
equal visual weight, so view-mode switching, formatting, save, and theme
controls compete for attention. All four alternatives address this by demoting
view-mode and theme switching out of the primary formatting row.

## Markdown Editor Redesign A: Quiet Paper

Mockup: [markdown-editor-redesign-a-quiet-paper.html](markdown-editor-redesign-a-quiet-paper.html)

A writing-first design. Warm paper background, narrow centred serif column,
and the toolbar collapses into a floating pill at the bottom with only the
high-frequency controls. Block styles live behind an `Aa` menu and structure
controls behind an overflow menu. Mode switching becomes plain text links in
the top bar. Save state is a passive coloured dot that leans on the existing
autosave behaviour.

Trade-offs and effort: cheapest to reach from the current implementation. It
is mostly CSS plus regrouping the existing Web Awesome controls. It suits a
personal-notes use of the editor, but hides structure controls behind an extra
click.

## Markdown Editor Redesign B: Dark Workbench

Mockup: [markdown-editor-redesign-b-dark-workbench.html](markdown-editor-redesign-b-dark-workbench.html)

An IDE-style design that leans into the tooling the editor already has. Split
view becomes the default rather than a mode: CodeMirror with line numbers and
syntax-coloured Markdown on the left, live preview on the right. A file tab
carries a modified-state dot, an icon rail anchors the left edge, and a status
bar carries autosave countdown, document format, cursor position, word count,
and encoding.

Trade-offs and effort: moderate effort. This direction fits a developer
audience and gives the save and autosave states a natural home in the status
bar instead of a mutating Save button. It spends more horizontal space and
makes the visual-only mode secondary.

## Markdown Editor Redesign C: Workspace Studio

Mockup: [markdown-editor-redesign-c-workspace-studio.html](markdown-editor-redesign-c-workspace-studio.html)

A Notion-style document workspace. A document sidebar anticipates
`GET /documents/:id` growing beyond `home`. A breadcrumb header carries
passive `Saved just now` text. The persistent toolbar is removed entirely:
formatting happens through a floating bubble toolbar on text selection, and
blocks are inserted through a slash command menu.

Trade-offs and effort: the largest behavioural change. Tiptap supports both
the bubble toolbar and slash menu patterns well, but the popover and toolbar
state involved would strengthen the case for the deferred Lit spike recorded
in the Phase Six notes of
[markdown-editor-spike.md](../design/markdown-editor-spike.md).

## Markdown Editor Redesign D: Bold Press

Mockup: [markdown-editor-redesign-d-bold-press.html](markdown-editor-redesign-d-bold-press.html)

A neo-brutalist design. Thick black borders, a yellow canvas, an offset-shadow
document panel, and every control is a labelled text button rather than an
icon, which removes the tooltip dependency entirely. Save is a prominent slab
and save status is a timestamped chip below the document.

Trade-offs and effort: moderate effort, but it means abandoning Web Awesome's
default theme contract in favour of heavy custom styling. It is the most
distinctive and most discoverable option, at the cost of visual noise and
toolbar width.

## Markdown Editor Redesign E: Phosphor Terminal

Mockup: [markdown-editor-redesign-e-phosphor-terminal.html](markdown-editor-redesign-e-phosphor-terminal.html)

A retro phosphor-green terminal in the style of DOS-era full-screen editors.
A menu bar sits across the top, the document lives inside a box-drawing frame
whose title carries the file name and mode switch, the heading renders as
inverse video, and a Midnight-Commander-style function-key bar replaces the
toolbar entirely. A vi-style status line carries insert mode, cursor position,
word count, and save time. The modified flag is an amber marker in the menu
bar.

Trade-offs and effort: keyboard-first to the point of hostility for mouse
users, and the function-key contract conflicts with browser and OS function
key bindings, so the keys would be cosmetic labels over click targets. Visual
styling is cheap (one font, three colours, no component library), but
discoverability is the worst of the eight.

## Markdown Editor Redesign F: Broadsheet Gazette

Mockup: [markdown-editor-redesign-f-broadsheet-gazette.html](markdown-editor-redesign-f-broadsheet-gazette.html)

A broadsheet newspaper. The page has a masthead with a dateline that carries
the save state, a small-caps proofing toolbar where each inline mark is
previewed in its own style (italic shown in italics, strike shown struck
through), and the document body is set as two justified columns with a drop
cap and a column rule. Saving is `Save edition`; the footer reads like a
print colophon.

Trade-offs and effort: the strongest typographic identity of the eight, and
the toolbar-as-specimen idea genuinely improves recognisability of inline
marks. Justified multi-column text is a poor fit for an editable surface
(caret travel across columns is disorienting), so the columns would likely
need to collapse to one while editing and only render as a broadsheet in a
preview mode.

## Markdown Editor Redesign G: Candy Pop

Mockup: [markdown-editor-redesign-g-candy-pop.html](markdown-editor-redesign-g-candy-pop.html)

A playful, toy-like design. View modes are labelled pill tabs, formatting
controls are large round pastel buttons grouped by colour (inline marks in
purple, list and quote structures in teal, block furniture in coral), the
writing surface is a soft white card with heavily rounded corners, and the
word count is a daily-goal progress bar. Save state is a friendly `All saved`
chip rather than a button.

Trade-offs and effort: the colour-grouped controls are genuinely useful for
learnability, and the large hit targets suit touch devices. The aesthetic
fights the developer-tool positioning of MicroHttp, and the daily word goal
implies feature work (streaks, goals) that the spike does not have. Moderate
styling effort on top of the existing controls.

## Markdown Editor Redesign H: Dungeon Scroll

Mockup: [markdown-editor-redesign-h-dungeon-scroll.html](markdown-editor-redesign-h-dungeon-scroll.html)

A fantasy role-playing-game interface. The document is a parchment scroll
inside a dark wooden frame, formatting controls are inventory slots with
pixel-style double borders, view modes are `Quill`, `Runes`, and `Both`,
saving is an `Inscribe` action that records a revision to the archive, and
the word count is an experience bar toward the next scribe level.

Trade-offs and effort: the most extreme reskin, and the revision-archive
framing is the one idea worth stealing (save history presented as numbered
inscriptions maps well onto a future filesystem store with versioning). As a
whole design it is a novelty: heavy custom styling, no component library
support, and the metaphor labels hide standard editing vocabulary.

## Second Round (2026-06-15)

Five further directions, chosen to be distinct from one another and from the
first round: a technical blueprint, a glassmorphism surface, a comic book, a
Bauhaus composition, and a naturalist herbarium.

## Markdown Editor Redesign I: Blueprint Drafting

Mockup: [markdown-editor-redesign-i-blueprint-drafting.html](markdown-editor-redesign-i-blueprint-drafting.html)

An engineering-drawing blueprint. Cyan grid on a navy ground, the document
drawn inside dimension lines (column width, sheet size), formatting controls as
a left drafting-tool rail with text labels, and an engineering title block
along the bottom carrying mode, revision, word count, and save state. Modes are
tabs in the title bar; save is a `Plot` action.

Trade-offs and effort: heavy custom styling that abandons the Web Awesome theme
contract. The labelled tool rail removes the tooltip dependency and the
title-block-as-status gives save and revision a natural home; the `REV` field
hints at a versioned store, like Dungeon Scroll's archive but understated. The
technical identity suits the developer-tool positioning, though a cool palette
can read as cold for a writing surface.

## Markdown Editor Redesign J: Aurora Glass

Mockup: [markdown-editor-redesign-j-aurora-glass.html](markdown-editor-redesign-j-aurora-glass.html)

A modern glassmorphism surface. Frosted translucent panels float over a vibrant
aurora gradient: a glass segmented control for the view modes, a blurred
floating toolbar, and a softly glowing `Saved` pill. The writing card is itself
frosted glass with an inner highlight.

Trade-offs and effort: mostly CSS over the existing controls, and very much of
the moment. `backdrop-filter` blur is widely supported but GPU-costly and
degrades to flat translucency where it is not; legibility over a busy gradient
needs contrast care. The consumer-SaaS aesthetic sits a little at odds with the
developer-tool positioning.

## Markdown Editor Redesign K: Inkpress Comic

Mockup: [markdown-editor-redesign-k-inkpress-comic.html](markdown-editor-redesign-k-inkpress-comic.html)

A black-and-white comic book. Halftone screentone paper, thick inked panel
borders with hard offset shadows, the toolbar housed in a speech bubble with a
tail, and the save state as a yellow action-burst star (`Saved!`). The heading
is heavy italic display lettering with a colour-pop shadow.

Trade-offs and effort: bold and memorable, and staying black-and-white with one
accent keeps it from competing with Candy Pop's colour. Cheap to style (no
component library, one accent), but a novelty: the rotated panels and faux
display lettering fight a precise editing surface, and the metaphor adds visual
noise.

## Markdown Editor Redesign L: Bauhaus

Mockup: [markdown-editor-redesign-l-bauhaus.html](markdown-editor-redesign-l-bauhaus.html)

A constructivist composition. Primary red, blue, and yellow with black on warm
off-white, a circle/triangle/square mark, inline-mark controls as colour-coded
tiles down a left rail, a red triangle wedge motif, and a strict asymmetric
grid. Save is a black slab with a yellow disc.

Trade-offs and effort: a timeless design-school identity, distinct from the
web-brutalist Bold Press -- refined rather than loud. The colour-coded tiles aid
learnability the way Candy Pop's do but read as serious. It abandons the Web
Awesome contract for heavy custom styling, and the geometric display type needs
a real geometric font (Futura and similar) to land.

## Markdown Editor Redesign M: Herbarium

Mockup: [markdown-editor-redesign-m-herbarium.html](markdown-editor-redesign-m-herbarium.html)

A naturalist herbarium journal. A pressed-specimen sheet on ruled paper,
formatting controls as botanical specimen labels (icon plus name), a botanical
leaf illustration in the margin, and a `Pressed & catalogued` save state with a
sage wax seal. The header reads as a specimen card with a number.

Trade-offs and effort: calm and distinctive without the austerity of Quiet
Paper. The specimen-label toolbar is legible with no tooltip dependency, and the
catalogue framing maps onto a future versioned store (the Dungeon Scroll archive
idea, understated). The naturalist theme is decorative for a developer tool, and
the ruled background is cosmetic only; moderate styling over the existing
controls.
