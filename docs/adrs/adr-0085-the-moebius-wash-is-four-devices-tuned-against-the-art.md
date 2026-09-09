---
id: ADR-0085
name: The Moebius Wash Is Four Devices, Tuned Against the Art
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0085: The Moebius Wash Is Four Devices, Tuned Against the Art

> Status: Accepted (2026-08-09).

## Context

ADR-0081 gave the Moebius theme a texture layer, and that layer
was a speckle: sparse dots, ramped so they gather where the light falls
away. The speckle left every surface one uniform colour with dots on it,
which is not what the reference art does. In the Giraud pages under
docs/mockups/images the wash itself is blotchy, a tone shifts hue as it
crosses a shape, shadow is drawn as hatching rather than as a darker
fill, and paint chips off in outlined flecks. Reaching for "less flat"
by simply raising the speckle's strength only makes a dirtier uniform
colour.

## Decision

The wash is four separate devices, each with its own job, and
each is a self-contained SVG data URI used as a background layer under
ADR-0081's existing texture rules. Low-frequency mottling makes the wash
uneven. A cool-to-warm hue fade carries the light across each panel,
with its changeover dithered into stipple rather than blended. Hatching
draws shadow and contour. Bordered flecks are chips of paint. None of
them is an overlay, for ADR-0081's reason: an overlay needs its host
positioned, and repositioning this chrome unpins the sticky bar.

The wash REPLACES the speckle; the two do not both ship. They are the
same idea at the same frequency, so a surface carrying both reads as
noise rather than as paper, and every setting below was judged with the
speckle switched off. The speckle and its three dead strength tokens are
therefore removed from the theme, and its own tuning survives only in
this file's history and in the day-and-night mockup.

Three constraints follow from the devices themselves rather than from
taste. Each layer's SVG is authored at its host element's nominal pixel
size, because the layer stretches to the element and authoring at that
size keeps a blotch the same physical size on every panel. The hatch is
the one layer that tiles instead of stretching: a hatch is directional,
so a stretch swings its angle and fattens its strokes, where isotropic
noise merely goes elliptical. And a device is placed by what it means,
not spread over everything -- hatching only where a surface turns away
or an object casts shadow, flecks only on surfaces that read as objects,
and no hue fade on the command bar, because a small drawn object holds
one colour.

Applying the wash also settled three surface colours that the theme and
the mockup disagreed on. The rail was a flat fill where the mockup gives
it hard-edged colour bands -- a banded sky at the top falling to sand by
day and to the night's lighter blue at the foot -- and the theme now
takes the bands. The night editing field went the other way: the mockup
paints it `#1d2150`, the theme painted the deeper `#12142f`, and the
deeper indigo is the one kept, with the mockup brought into line rather
than the theme. Both now come from theme-private tokens
(`--moebius-rail`, `--moebius-page`) rather than from the general editor
background, which is what let the two drift apart in the first place.

Two consequences follow. The head art at the rail's top loses the 88px
sky band it used to paint, because that band was a second, smoothed sky
that ended on the old flat colour and drew a seam across a banded rail;
the sun, moon, birds, and stars now sit directly on the rail's own top
band, as they do in the mockup. And the rail's sticky header, which
needs an opaque background of its own, can no longer use the editor
background -- it takes the rail's band and cool wash with viewport
attachment, which lands on the same colour as the nav behind it because
the nav's box is exactly the viewport.

The hue fade is FOLDED INTO each surface's own gradient rather than laid
over it. An overlay had to be tamed at night -- every tint is lighter
than the indigo page, so compositing one normally could only fade by
making the panel paler -- and the fix, `background-blend-mode: color`,
worked but left a stylesheet nobody could read: the painted colour was
not in the file, and predicting it meant knowing how `color` blending
behaves. The tokens now carry literal stops (`--moebius-rail`,
`--moebius-page`, `--moebius-bar-hi`, `--moebius-bar-lo`), so a panel's
appearance can be read straight off its value, and no blend mode or
translucent layer survives.

The night stops are computed at constant luminance: the tint contributes
hue and saturation while the surface keeps its own depth. This is the
part a naive fade cannot express, and it is worth stating plainly --
`#3d2a5c` carries 4.1x the luminance of `#12142f`, so interpolating
toward it bleaches the panel whether or not that was the intent. Scaling
the tint to the surface's luminance first removes the lift and leaves
the colour change. Day needs none of it: its tints are already darker
than the paper, so they shade as they go.

Two consequences of folding rather than overlaying. The top bar's own
bands run vertically while its fade runs across, and one gradient cannot
do both, so its upper row paints itself -- which the app already did --
and the bar is free to be the fade. That row is opaque, so it also has
to carry its own texture, sharing the bar's fleck seeds and tile origin
so the pattern runs on across the join. And a surface can be given less
of the fade than its neighbours: the top bar takes 40%, being small and
strongly coloured, where the full weight swamped it.

The settled strength is a full hue shift with the luminance held. The
prototype's slider drives the two knobs in sequence -- hue depth below
centre, luminance travel above it -- because alpha alone saturates once
the ends reach the tint, which is why raising it stopped doing anything.
Centre is what is baked here.

The rail and the metadata panel also stop using the muted tone for their
labels. Muted is a quiet grey-brown chosen against a flat surface, and
this rail is not flat: it measured 2.09:1 against its deep sand band,
for page names rather than incidental captions. Both columns take the
text tone, which holds 5.99:1 on the worst band, and the contents list
is named explicitly because it sets muted on its own container and would
otherwise have left the panel two-toned.

The night hue fade also changes target. Its warm end was the red-rock
ember, which against a dark indigo page was too large a step and read as
a second colour arriving rather than as light falling away; it is now
the sky's own purple, `#3d2a5c`, and a little weaker with it. The day
fade is unchanged. These are ADR-0081 corrections rather than new
decisions.

The settings are not derived in the stylesheet. They were tuned round by
round against the reference art in
docs/mockups/markdown-editor-moebius-watercolour-prototype.html, which is
the record of what was tried and rejected -- including chromatic
granulation, which was dropped, and pigment edge pooling, which never
read as anything but a border. Densities that matter were measured off a
canvas rather than judged by eye: the flecks sit at 0.43% coverage
because 5.3% read as terrazzo. The prototype, not this register, is
where a future change to the numbers starts.

## Consequences

The theme's surfaces are no longer flat. ADR-0081's three
layers stand, with its texture layer now meaning the wash rather than
the speckle, and its rule that only scenery names literal colours
extends to these textures, which are equally drawn art. Chromatic
granulation stays dropped for the same reason the speckle is gone. A
theme that wants this treatment needs art direction per surface, not a
token swap, so the wash does not generalise to the other visual themes
for free.
