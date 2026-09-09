---
id: ADR-0081
name: The Moebius Theme Skins the Chrome without Restructuring It
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0081: The Moebius Theme Skins the Chrome without Restructuring It

> Status: Accepted (2026-08-05).

## Context

RFC-0035 left the visual-theme mechanism as "token re-skins plus
an optional structural layer, keyed on data-editor-theme", with Studio the
only structural example. The Moebius theme (designs R and S in
docs/mockups, and the day-and-night pairing prototype beside them) is the
first full re-skin: a Jean Giraud desert with drawn scenery, hand-drawn
line wobble, and a speckled grain that shades each panel. (That grain is
superseded by ADR-0085: the texture layer is now the wash, and the
speckle has been removed rather than kept alongside it. The rest of this
decision stands.) Three of its
devices do not fit a plain token swap. The scene has an hour of day baked
in, so it needs the colour-scheme switch to mean noon or night rather than
lighter or darker. The scenery is art, not colour. And the wobble is an
SVG filter, which cannot be expressed in a stylesheet alone.

## Decision

The theme ships as tokens plus a texture layer, with no change
to the chrome's structure or markup.

1. Both Basecoat's token names and the --markdown-editor-* names are
   redefined under `:root[data-editor-theme="moebius"]`, and again under
   `...moebius"].dark` for the night. Light and dark are the same desert
   twelve hours apart, not two brightnesses, so the scheme switch already
   in the top bar is the hour control and no new preference is added.
2. Scenery and grain are inline SVG data URIs used as background layers:
   no extra request, and nothing to resolve against the document. The
   rail's scenery rides its root list (padding reserves the room) so it
   scrolls with the tree and never sits under a page name; the rail's own
   grain is a pinned background layer, because an absolutely positioned
   overlay inside a scroll container scrolls away with the content. The
   editing field's grain is attached to the viewport
   (`background-attachment: fixed`): the grain belongs to the surface the
   reader is looking at, not to the document's length. Sized to the
   element instead, a 46,000px column stretched the dots into streaks and
   pushed the ramp's start 27,000px down the page, so a long document
   showed no grain at all where it was being read.
3. The wobble does need live filters, so the editor element injects one
   hidden defs block when the theme is chosen
   (`ensureMoebiusFilterDefs`). It is applied only to controls that hold
   no popover: `filter` makes an element a containing block, which would
   re-anchor a menu positioned inside it. Dropdown triggers, the command
   bar and the search field are deliberately left straight. The wobble
   also needs something to waver: at the chrome's default hairline it was
   invisible, so this theme sets a 2px control line and gives every quiet
   (ghost) control an opaque face, which the transparent default let the
   sky band and the rock show straight through.

A theme must not override `position` on this chrome. The top bar and the
footer are sticky; a `position: relative` added to host a grain overlay
silently unpinned the top bar, which then scrolled away with the page.
Grain is therefore carried as background layers, which need no positioning
and clip themselves to an element's border radius.

A re-skin also has to set Basecoat's `--sidebar-accent`, not only
`--accent`: both side panels hover on the former, so leaving it unset gives
a themed editor a neutral grey hover. And the top bar insets its rows by its
own inline padding, so a band painted on a row stops short at both ends --
it needs the padding cancelled by a negative margin *and* an explicit width,
because the row carries a width of its own. That band must also be scoped
under `.markdown-editor__topbar`: the version pages (history, search, trash)
reuse the toolbar class on its own, and an unscoped band painted itself
across their centred, narrow content, reaching neither edge.

Long straight edges are the one thing a filter cannot fix. The rail's right
border and the top bar's lower border are sticky or scroll containers, so
filtering them would unpin them and cost a full-height raster; a theme that
wants them drawn lays a tileable wave along the edge as a background layer
and makes the border itself transparent.

## Consequences

A theme can now change the whole look, including texture and
illustration, without touching a template or a component. The cost is that
the Moebius rules name their own selectors, so a future rename of a chrome
class has to be applied here too; the theme's rules are contiguous and
commented at the foot of markdown-editor.css to make that greppable. The
wobble's popover constraint is a standing rule for any future theme that
reaches for filters. The scenery reserves roughly 13rem of the page tree's
vertical space, which is the theme's own trade and not the default's.
