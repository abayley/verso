# Basecoat + Lit + htmx spike

Date: 2026-07-08. Spike code: `spike/basecoat-lit/` (serve with the
`basecoat-lit-spike` launch configuration, port 5176; static files, CDN
dependencies, no build).

## Question

Before adopting Basecoat (RFC-0035) as Verso's chrome styling: does Basecoat's
vanilla-JS component runtime compose with Verso's two DOM-owning mechanisms --
light-DOM Lit elements and htmx swaps? Basecoat mutates attributes
(`aria-expanded`, `aria-hidden`, `data-*-initialized`) on markup that Lit also
renders, and its components need explicit initialisation for DOM it did not
see arrive.

## Method

A static page with a Basecoat dropdown menu (the most stateful chrome
component: trigger + popover + menu, keyboard nav, outside-dismiss) exercised
three ways:

1. rendered inside a light-DOM Lit element (`createRenderRoot` returning
   `this`, matching Verso's convention), with `window.basecoat.initAll()`
   called from `updated()`;
2. re-rendered by Lit both in place (a bound counter elsewhere in the same
   template) and structurally (switching template branches, which replaces
   the dropdown subtree);
3. swapped in by htmx, with `initAll()` called from an `htmx:afterSwap`
   listener.

## Findings

All composition cases pass:

- A dropdown rendered by Lit initialises via `initAll()` in `updated()`
  (idempotent; guarded by `data-dropdown-menu-initialized`).
- An OPEN dropdown survives in-place Lit re-renders: lit-html only touches
  bound parts, so Basecoat's attribute mutations on statically-authored
  attributes persist. Corollary: never BIND the attributes Basecoat manages
  (`aria-expanded`, `aria-hidden`) -- a bound expression would re-assert the
  template value on every render.
- Lit event bindings (`@click`) inside Basecoat-managed menus fire normally.
- A structural re-render produces fresh uninitialised nodes; the `updated()`
  hook re-scans and they work. Switching back reuses lit-html's cached nodes
  (already initialised, listeners intact) -- also works.
- htmx swap and re-swap both work with the `afterSwap` -> `initAll()` hook.
  For history restores Basecoat documents `initAll({force: true})` (not
  exercised here).

One blocker, with a cheap mitigation:

- **CSS transitions on Lit-rendered popovers can freeze.** The popover's
  open-state transitions (opacity/scale/visibility, 100ms) started but their
  `currentTime` stayed pinned at 0 indefinitely, leaving the popover at
  `opacity: 0; visibility: hidden` despite correct attributes. This affected
  ONLY Lit-created nodes: byte-identical markup inserted via
  `insertAdjacentHTML` or via a manual `template.content` +
  `document.importNode` clone in the same location transitioned normally, so
  it is not template-cloning per se; the trigger is something in lit-html's
  node construction path interacting with the browser's transition timeline
  (observed in the preview harness's Chromium; not yet reproduced in a
  desktop browser).
- **Mitigation, verified:** `[data-popover] { transition: none !important; }`
  makes open/close instant and immune to the entire failure class. Cost: the
  100ms fade/scale flourish. Recommendation: ship the override from day one
  and treat re-enabling transitions as polish, gated on reproducing (or
  failing to reproduce) the freeze in real browsers.

Also relearned during the mockup work, recorded here because a migration hits
them immediately:

- Interactive components silently skip initialisation if the ARIA wiring is
  incomplete (`aria-controls` on the trigger, `aria-hidden` on the popover,
  ids linking trigger/popover/menu). Warnings only appear for partially-wired
  elements; unwired ones are ignored. Server-side template helpers must own
  this wiring.
- Basecoat's CSS-only tooltips are `position: absolute` pseudo-elements that
  count toward `scrollWidth`; near-viewport-edge placements need explicit
  `data-side`/`data-align` or they cause page overflow (phantom scrollbars).
- Basecoat declares Geist in its font stack but does not load it; without a
  vendored Geist the metrics quietly fall back to system-ui and nothing lines
  up with shadcn references.
- The deferred CDN runtime raced markup on a static page; an explicit
  `DOMContentLoaded` -> `initAll()` is harmless and removes the race.

## Conclusion

Composition is viable. The integration contract for Verso is:

1. `initAll()` after every DOM-producing event: `htmx:afterSwap` (one global
   listener), Lit `updated()` on components that render Basecoat chrome, and
   `DOMContentLoaded`.
2. Never bind Basecoat-managed attributes in Lit templates.
3. Ship `[data-popover] { transition: none }` until the frozen-transition
   interaction is understood.
4. Generate interactive-component markup exclusively through shared helpers
   (Haskell for server templates, TS for Lit templates) so the ARIA wiring
   has one owner.
