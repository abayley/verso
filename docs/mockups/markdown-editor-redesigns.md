# Markdown Editor Redesign Mockups

This document records alternative visual designs for the Verso Markdown
editor page at `/documents/:id?edit`. The first round (designs A to H) was
produced on 2026-06-10 as static HTML files in this directory: A to D are
practical directions, E to H deliberately extreme style explorations. A second
round (designs I to M) was added on 2026-06-15 -- five further directions, each
distinct from the others and from the first round. A third round (designs N to
R) was added on 2026-07-03, alongside a refresh of design L to match the
editor as it now is. They are design references only; they are not served by
Verso and are not part of the editor build.

Rounds one and two mock the editor functionality of their time: view modes,
block styles, inline marks, structure controls, save state, and theme
switching. The refreshed design L and round three mock the current editor
surface: draft editing with Publish and Cancel, the Visual/Markdown/Split
modes, Narrow/Medium/Full width, visual theme and light/dark/system scheme
switching, the page navigation tree (create, move-undo, trash, per-page add
and delete), the Contents/Attachments/History sidebar, and the floating
command bar (block style, inline marks, lists, quote, code block, rule,
badges, callouts, tables, collapsibles, image and file upload, and draft
save state). Only the visual treatment and control placement change.

The mockup files use the Tabler icon webfont from a CDN, so icons need network
access to render. Open the files directly in a browser.

## Markdown Editor Current Design Observations

At the time of the first round, the page was the default Web Awesome look: one
dense, full-width icon toolbar over a borderless white surface. All seventeen
or so controls carried equal visual weight, so view-mode switching,
formatting, save, and theme controls competed for attention. Designs A to D
address this by demoting view-mode and theme switching out of the primary
formatting row. The production editor has since adopted several of these
ideas: a floating command bar, a sticky top bar for mode/width/theme/scheme
switching, a document sidebar, and passive save state.

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
off-white, a circle/triangle/square mark, a red triangle wedge motif, and a
strict asymmetric grid.

Refreshed on 2026-07-03 to match the current editor surface: Publish is a
black slab with a yellow disc beside a bordered Cancel, the ruled header
carries mode, width, theme, and scheme switches, the page tree is a left rail
with geometric bullets, Contents/Attachments/History form a right rail, and
the command bar is a strip of colour-coded tiles with the draft save state as
a black tile with a yellow dot. The refresh also borrows from Mondrian's
neoplasticism: black rules of deliberately unequal weight between regions, a
small Mondrian composition filling the dead space at the foot of the page
tree, and a Broadway Boogie Woogie segmented strip as the frame's bottom
edge.

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

## Third Round (2026-07-03)

Five further directions, each mocking the current editor surface (drafts,
navigation tree, sidebar, command bar): a Roy Lichtenstein pop-art panel, a
Patrick Caulfield interior, a monochrome line-art treatment, a linocut print,
and a Moebius desert.

## Markdown Editor Redesign N: Ben-Day Pop

Mockup: [markdown-editor-redesign-n-benday-pop.html](markdown-editor-redesign-n-benday-pop.html)

A Roy Lichtenstein pop-art panel. Ben-Day dot screens in primary red, yellow,
and blue, thick black outlines with hard offset shadows, italic display
lettering with a colour-pop shadow, sunburst rays behind the frame, the
sidebar sections as yellow comic caption boxes, the command bar in a speech
bubble, and the draft save state as a rotated `Saved!` starburst.

Trade-offs and effort: the loudest identity in the set, and clearly separated
from Inkpress Comic (K), which stays black-and-white -- this is the full-colour
half of the comic idea. The caption-box sidebar gives the panel headings free
visual hierarchy. Heavy custom styling with no component library support, the
dot screens add noise behind small text, and the joke may wear thin for daily
writing.

## Markdown Editor Redesign O: Caulfield Interior

Mockup: [markdown-editor-redesign-o-caulfield-interior.html](markdown-editor-redesign-o-caulfield-interior.html)

A Patrick Caulfield interior. Flat planes of saturated ultramarine with
uniform black contour lines and no gradients or shadows anywhere in the
chrome; a flat yellow lamp casts a flat light beam across the frame;
lowercase labels throughout. The one Caulfield device worth naming: as in his
paintings that embed a single photorealistic passage inside a flat room, the
document is the one naturalistic, finely detailed surface (serif type on
cream) while every control around it stays flat colour and contour.

Trade-offs and effort: calm, saturated, and unlike anything else in the set;
the flat-room/detailed-page contrast genuinely expresses "the chrome is
furniture, the page is the subject". Heavy custom styling, a dark saturated
ground needs contrast care for small text, and the wit is quieter than
Ben-Day Pop -- it reads as a designed room rather than a costume.

## Markdown Editor Redesign P: Line Art

Mockup: [markdown-editor-redesign-p-line-art.html](markdown-editor-redesign-p-line-art.html)

A monochrome line-art treatment. Pure white, one 1.5 pixel ink weight for
every border, icon, divider, and the caret; no colour and no fills. Selection
and active states are diagonal hatching, the page tree hangs from drawn
connector lines, the callout label sits in a gap in its own outline, Publish
is a double-ruled pill, and the command bar is a single outlined pill.

Trade-offs and effort: the cheapest of the round by far -- it is almost
entirely borders and one hatch pattern, and Tabler's stroke icons already
match the line weight. Distinct from Blueprint (cyan on navy) and Inkpress
(halftone screentone) despite sharing the drawn-line idea. State legibility
carries the risk: with no colour, hover, focus, selection, and error states
all have to come from hatching, weight, or motion, and a hatched save dot is
weaker than a coloured one.

## Markdown Editor Redesign Q: Linocut

Mockup: [markdown-editor-redesign-q-linocut.html](markdown-editor-redesign-q-linocut.html)

A linocut / woodcut print. Heavy black ink on cream paper, with white gouge
strokes carved through every solid area (a repeating-gradient texture), knife
hatching behind the sidebar panels, and vermillion as the single second block
colour with off-register offsets. The frame has sawtooth carved edges top and
bottom, several blocks sit a fraction of a degree off square as if
hand-pulled, and the page tree ends in a small print of hills and a red sun.

Trade-offs and effort: a warm, handmade identity that is bolder than
Herbarium and quieter than Ben-Day Pop; the two-colour discipline keeps it
coherent. The carved texture is one CSS gradient so styling cost is moderate,
but true rough edges would need SVG masks, the deliberate misalignments fight
a precise editing surface, and heavy ink areas dominate on large screens.

## Markdown Editor Redesign R: Moebius

Mockup: [markdown-editor-redesign-r-moebius.html](markdown-editor-redesign-r-moebius.html)

A Jean Giraud / Moebius desert. Fine sepia contour lines of one weight
instead of black, flat colour laid in hard airbrushed sky bands, a banded sun
and drifting birds in the header, dunes at the foot of the page tree,
floating crystals over the document, and terracotta and turquoise picking out
the active controls. Letter-spaced capitals stand in for BD hand-lettering,
and the callout label sits in a small caption plaque.

Trade-offs and effort: the calmest of the illustrated identities -- vast,
airy, and closer to a usable daily surface than the other costumes because
the document plane itself stays plain cream with fine rules. The banded
palette needs care in dark scheme, the decorative SVGs (sun, dunes, crystals)
are fixed art that must be drawn per breakpoint, and the sepia-on-cream
contrast sits close to accessibility limits for small text.
