# Markdown Editor Redesign Mockups

This document records eight alternative visual designs for the TestApp
Markdown editor page at `/documents/home/edit`. The mockups were produced on
2026-06-10 as static HTML files in this directory. Designs A to D are
practical directions; designs E to H are deliberately extreme style
explorations. They are design references only; they are not served by the
TestApp and are not part of the editor build.

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
