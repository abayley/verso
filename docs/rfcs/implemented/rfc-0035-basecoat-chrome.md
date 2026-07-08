---
id: RFC-0035
name: Basecoat Chrome (shadcn Styling without React)
status: Implemented
owners:
    - alistair
created: 2026-07-08
updated: 2026-07-08
supersedes: []
superseded_by: null
---

# Basecoat Chrome (shadcn Styling without React)

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-07-08 |
| Started   | 2026-07-08 |
| Completed | 2026-07-08 |

## Summary

Adopt Basecoat (basecoat-css, MIT) as Verso's chrome styling system,
replacing Web Awesome components and most hand-written chrome CSS with
shadcn/ui-styled plain HTML: classes plus `data-variant`/`data-size`
attributes, a small vanilla-JS runtime for the interactive components, and
shadcn-compatible theme tokens. Our light-DOM Lit elements, htmx, and the
server-rendered architecture are unchanged; "component" becomes a shared
template helper rather than a custom element. The shadcn look stops being
theme number six and becomes the design language; surviving themes become
token re-skins over Basecoat's variables.

## Context

Exploration (2026-07): a `shadcn` token theme (in `main`), a reference React
mockup (`~/git/shadcn/vite-app`), and a Basecoat mockup of Verso's full
editor layout (`~/git/shadcn/basecoat-app`) validated to metric parity with
the React reference (sidebar tree geometry, toolbar, top bar, ToC pane).
Token-level theming could not reach component fidelity through Web Awesome's
shadow DOM; Basecoat reproduces shadcn styling on markup we fully own. A
composition spike (`spike/basecoat-lit/`, findings in
`docs/design/basecoat-lit-spike.md`) confirmed Basecoat works inside
light-DOM Lit elements and across htmx swaps, with one guarded blocker
(popover transitions) and a documented integration contract.

Maintenance position: Basecoat tracks shadcn's visual evolution via npm
releases (1.0.0 realigned all style packs); hand-rolled CSS tracks nothing;
shadcn itself is copy-source with manual diffs. Version-bump maintenance is
the best available in this ecosystem.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Verso's chrome (buttons, inputs, dropdowns, tabs, tooltips, breadcrumbs,
  cards, badges, nav tree, search, toolbar) renders with shadcn styling via
  Basecoat classes, matching the validated mockups.
- Web Awesome is fully removed (markup, bundle, `webawesome.css`).
- The integration contract from the spike is implemented once, centrally:
  `initAll()` hooks, no Lit-bound Basecoat-managed attributes, popover
  transitions disabled, ARIA wiring generated only by shared helpers.
- `make check` stays green throughout; no network at build or test time
  (Basecoat CSS/JS and the Geist font are vendored).
- Behaviour contracts (mode selection, toolbar commands, save flow, nav
  operations) keep their existing tests; visual work stays browser-first.

## Non-Goals

- No Tailwind build step in this RFC. The vendored precompiled bundle
  (`basecoat-nova.cdn.min.css`) is sufficient; Tailwind adoption is a
  separate decision if utility classes are ever wanted.
- No redesign of editor content styling (the document surface, code fences,
  badges inside documents keep their existing CSS except where chrome
  overlaps).
- No new themes; theme retirement decisions are made here but re-designing
  survivors is follow-up work.
- No change to the Lit element inventory or the htmx interaction model.

## Proposal

### Assets

- Vendor `basecoat.cdn.min.css` (nova style pack), `js/all.min.js` (or the
  per-component scripts once the used set is known), and Geist Variable
  woff2s into `static/editor/`, copied by `scripts/build-editor.mjs` from
  `node_modules/basecoat-css` (dev dependency, version-pinned).
- `markdown-editor.css` keeps: layout, document content styling, and theme
  structural layers; loses: hand-written chrome (button/input/pill styling,
  the Web Awesome token bridge).

### Component helpers

- Haskell: a `Verso.Chrome` module with helpers -- `chromeButton`,
  `chromeDropdown`, `chromeTabs`, `chromeTooltip` -- owning the
  class/attribute/ARIA conventions. Interactive markup is generated only
  through these.
- TypeScript: equivalent helpers for Lit templates
  (`src/Verso/Editor/chrome.ts`), sharing the conventions by construction
  (same attribute vocabulary; parity asserted in editor tests).
- Presentation isolation principle: helper call sites state semantic intent
  (primary action, quiet control, icon button), and the helper maps intent
  to Basecoat variant/size/classes. Appearance vocabulary
  (`data-variant`/`data-size`) appears ONLY inside the two helper modules,
  so restyling a class of controls is a one-line helper change, never a
  call-site sweep. Combined with the BEM test contract and the `@layer`
  override story, this keeps the three appearance tiers isolated: token/CSS
  changes need no code, variant changes touch only helper modules, and
  structural layout changes touch only view templates.
- View extraction is a completed move, not an opportunistic one: by the end
  of Phase 4 every page shell and fragment renders from a `Verso.View`
  module (controls from `Verso.Chrome`), and App.hs keeps only routing and
  handlers. End state is categorical: App.hs constructs no markup, so
  appearance diffs never appear in handler/routing code.

### Enforcement

The isolation rules are grep gates in `make check` (a `chrome-gates` step),
not conventions. Each activates once satisfiable on the migration branch:

- `data-variant`/`data-size` appear only in `Verso/Chrome.hs` and
  `Editor/chrome.ts` (active from end of Phase 3, once interactive chrome
  is helper-generated).
- App.hs contains no markup construction (no `Html.el`/`Html.input` calls;
  active from end of Phase 4, once view extraction completes).
- No `wa-` anywhere in `src/` (active at Phase 5, permanent).

### Integration contract (from the spike)

- One global `htmx:afterSwap` listener and a `DOMContentLoaded` hook call
  `window.basecoat.initAll()`; Lit elements that render chrome call it from
  `updated()`.
- Basecoat-managed attributes (`aria-expanded`, `aria-hidden`,
  `data-*-initialized`) are never Lit-bound.
- `[data-popover] { transition: none; }` ships with the migration
  (spike-observed frozen transitions on Lit-rendered popovers); re-enabling
  is polish, gated on real-browser reproduction.
- Tooltips near the viewport edge always carry `data-side`/`data-align`.

### Icons

Replace `wa-icon` (Font Awesome) with inline Lucide SVG symbols (the shadcn
convention; Basecoat ships no icons). Inventory (2026-07-08): all icon usage
goes through `wa-icon` -- ~20 sites across seven files (App.hs plus six
editor modules, including the code-fence copy button); there is no other
Font Awesome coupling. A generated sprite of the used icons is embedded in
the page shell; helpers reference symbols by id. Sizing follows the shadcn
conventions validated in the mockups (16px default, 14px scheme toggles,
12px sidebar header actions).

### Themes

Decided in the 2026-07-08 grill session:

- Two themes survive: `shadcn` (the new default, replacing Paper) and
  `studio`. Retired: Paper, Aurora, Blueprint, Workbench (with Workbench
  goes its open-in-split layout preset and IDE structural layer).
- Studio is purely an interaction-model switch: bubble toolbar + slash menu
  instead of the persistent command bar, visually identical to the default
  shadcn look. Its former Notion-ish visual identity can return later as a
  token sheet if missed.
- `safeEditorTheme`/`knownEditorThemes` fall back to `shadcn`; stored
  localStorage values naming retired themes fall back silently.
- The colour-scheme class moves from Web Awesome's `.wa-dark` to Basecoat's
  `.dark` convention (pre-paint bootstrap, scheme controls, and all
  `:root.wa-dark` CSS keys updated together).
- The theme dropdown control stays (two entries today; future themes keep it
  justified).
- Future radical themes (the docs/mockups explorations: moebius, line-art,
  bauhaus, ...) remain feasible, in three layers: (1) palette/radius/font as
  shadcn token overrides; (2) a per-theme component override sheet for what
  Basecoat bakes in (border weight, shadows, casing) -- Basecoat's CSS is
  entirely inside `@layer`, so un-layered theme sheets win every cascade
  fight without `!important`; (3) ornament and layout as theme structural
  CSS, exactly as today. Helper-generated markup gives every control
  identical anatomy, so one override per component class covers the whole
  app.

### Phases

The migration is implemented on a single branch and merged in one hit
(decided 2026-07-08: sole implementer, no coexistence period on `main`).
Phases survive as ordered commits on the branch, each internally green
(`make check`, `bun run editor:check`); the merge is gated on the full suite
plus browser verification. Web Awesome and Basecoat coexist only within the
branch's middle commits.

Test contract rule: the `markdown-editor__*` BEM classes stay on elements
alongside Basecoat's classes as the stable behaviour-test selector contract.
Behaviour tests change only where the interaction contract genuinely changes
(the ~10 `wa-select`/`wa-dropdown-item` sites in
`test/editor/markdown-editor-element.test.ts`).

#### Phase 1: Foundation

- [x] Vendor Basecoat CSS/JS + Geist via build-editor.mjs; serve from
      `static/editor/`; page shell loads them.
- [x] Global `initAll()` hooks (DOMContentLoaded, htmx:afterSwap) and the
      popover transition override.
- [x] `Verso.Chrome` + `chrome.ts` helpers for button, dropdown, tooltip,
      tabs; unit tests for the ARIA wiring (the silent-skip failure mode).
- [x] Lucide sprite pipeline for the icon set in use.

#### Phase 2: CSS-only chrome

- [x] Buttons, inputs, badges, cards across server templates (Edit/Publish/
      Cancel, search box, history page controls, dialogs' static parts).
- [x] Breadcrumb and top-bar layout to the validated geometry, keeping the
      Visual/Markdown/Split and Narrow/Medium/Full tab groups centred over
      the content column (per the mockups; explicit user requirement).
- [x] Server templates move into `Verso.View` as each surface migrates
      (extraction runs through Phases 2-4, complete by end of Phase 4).

#### Phase 3: interactive chrome

- [x] Theme dropdown + scheme toggle group (the spike's exact shape).
- [x] Editor toolbar in the Lit templates via `chrome.ts` (34px toggles,
      dropdown menus); toolbar behaviour tests updated to the new markup.
- [x] Tooltips replace `wa-tooltip` usage.

#### Phase 4: navigation surfaces and theme consolidation

- [x] Nav tree adopts the sidebar conventions (left chevrons, 28px sub-rows,
      indent guide at the chevron line) inside the existing Lit element.
- [x] ToC/attachments/history pane typography per the mockup.
- [x] Theme consolidation: default becomes `shadcn`; Studio reduced to the
      interaction-model switch; Paper/Aurora/Blueprint/Workbench CSS,
      registration entries, and Workbench's split-default removed;
      `.wa-dark` -> `.dark`; retirements recorded in the decision register.

#### Phase 5: removal

- [x] Web Awesome markup gone; dependency and `webawesome.css` removed from
      package.json, build, and the page shell.
- [x] Hand-written chrome CSS pruned from markdown-editor.css.
- [x] All three `chrome-gates` checks active in `make check`
      (variant-vocabulary containment, no markup construction in App.hs,
      no `wa-` in src/).
- [x] Docs: ADR-076 (Basecoat adoption, superseding the Tiptap ADR's Web
      Awesome clause; the Tiptap decision itself stands) and ADR-077 (theme
      retirements). The module index covers MicroHttp framework modules
      only, so no entry was needed for the Verso view/chrome split.

## Alternatives Considered

- Keep Web Awesome, restyle via its custom properties: shadow DOM caps
  fidelity (proven by the theme experiment); zero upstream tracking; rejected.
- Full shadcn (React): rewrites ~55 client modules and conflicts with the
  htmx server-rendered model; rejected.
- React islands for chrome: permanent dual-stack (React + Lit + htmx) for
  cosmetics; rejected.
- Hand-transcribe shadcn styles into our CSS: no upstream tracking; the
  mockup work showed how many conventions must be maintained by hand;
  rejected.
- Tailwind + Basecoat npm route now: adds a build step we do not yet need;
  deferred, not rejected.

## Security Impact

- Vendored third-party CSS/JS replaces vendored Web Awesome; same trust
  model, version-pinned, no runtime CDN fetches (removes the current htmx
  CDN exception? -- out of scope, noted in Open Questions).
- Basecoat JS is small and dependency-free; review at vendor time.

## Reliability Impact

- New failure mode: uninitialised components after DOM changes (silent
  no-op). Mitigated by centralised hooks + helper-owned wiring + tests
  asserting `data-*-initialized` after render in editor tests.
- Frozen-transition class of bugs eliminated by the transition override.

## Compatibility Impact

- Pure client-side presentation; no HTTP API or storage changes.
- Editor behaviour contracts preserved; toolbar/nav DOM shape changes will
  touch editor test selectors (expected, contained to `test/editor`).
- MicroHttp framework untouched; changes are Verso-only.

## Testing and Quality Gates

- `make check` (mhs gate) and `bun run editor:check` green per phase.
- New helper tests: ARIA wiring completeness (Haskell unit +
  vitest) -- the silent-init failure mode must be structurally impossible.
- Editor interaction tests updated alongside each surface's migration, not
  after.
- Browser-first verification against the two mockups (5173 React reference,
  5175 Basecoat reference) on the 8081 demo rig.

## Rollout Plan

1. One migration branch off `main`; phases land as ordered commits, each
   internally green.
2. Each surface is verified on the demo rig in both colour schemes before
   the next commit.
3. Phase 5 removal once no `wa-` markup remains (grep gate); merge to `main`
   in one hit after full-suite and browser verification.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts
  do not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- Does the frozen-transition behaviour reproduce in a desktop browser, or is
  it specific to the automated preview harness? (Determines whether the
  transition override is permanent or temporary; does not block the
  migration.)
- Should htmx also be vendored while we are consolidating third-party assets
  (currently loaded from jsdelivr at runtime)?
