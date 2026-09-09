---
id: ADR-0076
name: Basecoat Chrome Replaces Web Awesome
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0035]
---

# ADR-0076: Basecoat Chrome Replaces Web Awesome

> Status: Accepted (RFC-0035). Supersedes the Web Awesome clause of the Tiptap editing-engine decision (the "Use
> Web Awesome, the successor home for Shoelace, for future web-component UI controls" clause); the Tiptap decision
> itself stands.

## Context

The chrome needed the shadcn/ui look, validated against two
mockups (a React reference and a Basecoat replica measured to metric
parity). Web Awesome's shadow DOM capped restyling fidelity, and its
component vocabulary could not be reached by theme CSS. Basecoat
(basecoat-css, MIT) recreates shadcn styling as plain HTML classes plus
a small vanilla-JS runtime, is theme-compatible with shadcn, tracks
shadcn's visual evolution via npm releases, and documents htmx
re-initialisation (initAll) as a first-class integration.

## Decision

Vendor Basecoat's precompiled nova bundle, its runtime, and
the Geist Variable font (no Tailwind build). Generate all interactive
chrome markup through an intent-based helper pair -- Verso.Chrome for
server templates, Editor/chrome.ts for Lit and imperative DOM -- which
alone owns the Basecoat variant vocabulary and the dropdown/tab ARIA
wiring. Views render from Verso.View; App.hs keeps routing and handlers
only. Popover open/close transitions are disabled ([data-popover]
transition: none): the composition spike found transitions on
Lit-rendered popovers can freeze at currentTime 0, leaving open menus
invisible (docs/design/basecoat-lit-spike.md). Three grep gates in
make check (chrome-gates) enforce the containment.

## Consequences

Web Awesome is removed (dependency, bundle imports,
vendored CSS, wa- classes); tooltips are CSS-only (data-tooltip,
text-only, explicit data-side/data-align near viewport edges or the
tooltip pseudo-element widens the page); dialogs are native `dialog`
elements with Basecoat styling; icons come from a vendored Lucide
sprite referenced by `use` and styled via inherited stroke properties.
Upstream shadcn styling changes arrive by bumping basecoat-css.
