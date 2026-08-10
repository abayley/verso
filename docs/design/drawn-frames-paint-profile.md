# Hand-drawn frames on content components: paint profile

Status: analysis (2026-08-10). Preparatory work for putting the Moebius theme's wobble
on callouts, code fences and badges.

The Moebius theme wobbles its chrome with `filter: url(#moebius-wobble-a|b)`, but document
content does not wobble: callouts, fences and badges are drawn with straight CSS borders and
look machine-ruled against the rest of the theme. The prototype
(`docs/mockups/markdown-editor-moebius-watercolour-prototype.html`) already demonstrates the
treatment. The open question before carrying it into the theme was **paint cost at scale**:
each filtered element is its own raster with an SVG filter, and a document can hold a lot of
fences.

Short answer: paint cost is not the blocker. A structural problem is.

## What was measured

Playwright drove headless Chromium (1280x900) against the read-only view of
`many/code-samples.md` on the demo corpus, with the Moebius theme seeded into `localStorage`
under `editor-theme` -- the same state a user reaches from the top-bar picker.

The treatment: a drawn border on a pseudo-element, wobbled by the theme's own filter.
Filtering the pseudo-element rather than the block is settled -- filtering the block displaces
its monospace text and makes it a containing block, which relocates the fence's `position:
fixed` language menu by a measured 408px across and 622px down.

Each condition scrolled a fixed journey (120 frames, 12px a frame), traced over CDP, with the
treatment toggled on and off in interleaved repeats so drift could not masquerade as an
effect. The number reported is total `RasterTask` duration for the journey.

## Two measurements that had to be thrown away

**rAF frame intervals are meaningless headless.** Headless Chromium drives
`requestAnimationFrame` from a virtual clock: every condition read exactly 8.33ms and no
condition could ever drop a frame. This says nothing about smoothness. Only trace totals are
real work.

**The first three runs measured a filter that never painted.** The treatment was applied to
`pre::before` at `inset: -5px`. `pre` computes to `overflow: auto`, so a pseudo-element that
far outside the padding box is clipped away entirely. The trace still showed a plausible
"cost", and the medians even moved in the right direction at some sizes -- all of it noise. A
red-border probe settled it in one screenshot: no red anywhere on the page. **Screenshot the
treatment in an unmistakable colour before believing any number about it.**

## The numbers

With the wash stripped to a flat colour, so the frames are the only filtered raster on the
page. Total RasterTask ms across the 120-frame journey, median of five repeats:

| fences | page height | frames off | frames on |
| -----: | ----------: | ---------: | --------: |
|      5 |       912px |      1.5ms |     2.0ms |
|     65 |     6,934px |     25.0ms |    25.1ms |
|    155 |    15,967px |     23.0ms |    21.1ms |
|    405 |    41,058px |     18.1ms |    15.4ms |

The frames' cost sits at or below the noise floor, and **it does not grow with the document**.
That is the structural point: only what is in the viewport rasters, so the cost is bounded by
how many frames fit on screen -- about six -- not by how many the document holds. A 405-fence,
41,000px page is no worse than a five-fence one. It also did not hang, which the ~46,000px
`hangrepro` fixture has done to probes before.

One in five "on" runs threw an outlier (roughly double the median). The medians are flat, so
this reads as an occasional extra raster burst rather than a trend, but it is unexplained.

With the wash left on -- what actually ships -- the totals ran 24ms to 240ms with the "off"
arm's median *above* the "on" arm's. That comparison is worthless as a measure of the frames,
and it is the finding: **the wash costs an order of magnitude more than the frames, and its
variance is large enough to swallow them completely.** If anything here is ever worth
optimising, it is the wash, not the frames.

Caveats: headless Chromium rasters in software, so these are CPU raster numbers, not GPU;
treat them as an upper bound on raster work rather than a prediction of what the GPU pipeline
will do. Measured on the read-only view, which shares the editor's markup and paint pipeline
but not ProseMirror.

## Related: pinning the wash to the viewport

The same harness settled a second question. On a long document the wash's fade was spread over
the document's height -- 20,239px on the `hangrepro` fixture, so about four per cent of the
ramp is on screen at once and it reads as a flat wash. Pinning it to the viewport fixes that,
but **how** it is pinned decides whether the page still scrolls.

Total RasterTask ms across a 120-frame scroll of that fixture, median of five:

| content wash | raster |
| --- | ---: |
| anchored to the element (as it was) | 34.9ms |
| `background-attachment: fixed`, all four layers | 6,499ms |
| `background-attachment: fixed`, gradient layer only | 9,017ms |
| pinned, SVG texture layers removed | 25.3ms |
| painted on a `position: fixed` backdrop | 14.2ms |

A fixed background cannot ride the scrolling layer, so every frame repaints the whole wash and
re-runs its `feTurbulence` -- about 53ms a frame. Pinning only some layers is worse, not
better. The pinning is not what costs; regenerating the textures every frame is, which is why
removing them makes the attachment route cheap again.

A `position: fixed` element does not move relative to the viewport, so the compositor rasters
it once and reuses it. The wash therefore moved to a fixed backdrop
(`.markdown-editor__content::before`), which is both what was asked for visually and slightly
cheaper than the unpinned original. It also stops the paper texture being stretched to the
document's height; the trade is that the grain now holds still while the text scrolls over it.

## The real blocker: the fence clips its own frame

`pre` is `overflow: auto`. A fence cannot carry its frame on its own pseudo-element while it
is a scroll container -- the frame is clipped out of existence, silently.

The numbers above were obtained with a wrapper element around each fence, which is one way out.
The implementation took a simpler one: the `overflow-x: auto` on `<pre>` is redundant. The base
design already scrolls long lines on the `<code>` inside it -- deliberately, so the language
picker and copy button stay put -- so the theme sets `overflow: visible` on the `<pre>` and the
frame is no longer clipped. No wrapper, no NodeView change.

## What was implemented

All three now carry the treatment in the Moebius theme, following the prototype: the
pseudo-element carries the border *and* the fill, and the block itself goes borderless.

- **Fences and callouts** -- a filtered `::before` at `inset: 0`, `z-index: -1`, with
  `isolation: isolate` on the block. The fence additionally needs `overflow: visible` in the
  theme, undoing the base rule's `overflow-x: auto`; long lines still scroll on the `<code>`,
  where the base design already puts them.
- **Badges** -- filtered *whole*, as the prototype has them, not via a pseudo-element. A badge
  is inline and can wrap, and a pseudo-element would give one rect around the union of its
  line fragments rather than a frame per fragment. Its text is short and not on a grid, so the
  wobble reads as drawn rather than as a fault. The colour filter `.badge` already carries has
  to be repeated in the same declaration -- `filter` is one property, so naming the wobble
  alone would drop it.

- **Callout titles** -- the kind's name leaves the flow and becomes a drawn cap straddling the
  top edge, as the mockup's `.callout .capn` has it, rather than a line of bold text inside the
  box. The mockup shows a single teal cap because it shows a single kind; the cap here takes
  the kind's own accent so a warning and a caution stay apart, with the accent's paired text
  token carrying contrast in both schemes. The cap is not filtered -- also the mockup's choice,
  since displacing type at 10px only blurs it.
- **Collapsibles** (ADR-054) -- the same frame as callouts. Without it they kept the old rule
  down the side and read as a different component sitting next to a framed one. The summary
  stays in the flow: it is the control that opens the block, not a label, so it keeps its hit
  area and rotating arrow. The frame is a pseudo-element at `inset: 0`, so it follows the
  block's height as it opens and closes.

Verified in both schemes and in the editor as well as the read view. The hazard the whole
pseudo-element rule exists for was checked directly: with the frames on, the fence's language
menu opens at exactly the same coordinates under Moebius as under the Default theme.
