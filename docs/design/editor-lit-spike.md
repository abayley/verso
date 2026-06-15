# Lit Decision-Test Spike

The decision test recorded in `markdown-editor-spike.md`: after decomposing the
editor shell into plain controllers (RFC-0002, done), rebuild *only* the toolbar
rendering plus the save and link popover view in Lit, keep the Tiptap and
CodeMirror adapters unchanged, then compare line count, event-wiring clarity,
state-transition clarity, test stability, Web Awesome interop, and
bundle/runtime cost. This is that spike.

Code: `spike/editor-lit/toolbar.ts` (a `LitElement` rebuilding the command-bar
toolbar, save-state view, and link popover), bundled with
`bun build spike/editor-lit/toolbar.ts --outfile spike/editor-lit/bundle.js`. It
reuses the real, framework-agnostic `SaveStateController` and renders Web Awesome
controls; it does not re-implement Tiptap/CodeMirror editing (the adapters are
out of scope per the decision test). It is throwaway and not wired into the
production editor.

## What was compared

The Lit `render()` template stands in for the imperative shell code that builds
and updates the same surface in `markdown-editor-element.ts`:
`createCommandBar` + `createStyleDropdown` (+ item) + `createInlineStyleButton` +
`createStructureButton` + `createSaveButton` + `createSaveError` +
`updateToolbarState` (the save/inline parts) + `applySaveView`, plus
`LinkPopoverController`'s `createEditor`/`createActions` DOM.

## Findings

- **Bundle/runtime cost: effectively zero.** Web Awesome 3 is built on Lit and
  declares `lit ^3.2.1` as a dependency, so Lit's runtime is *already* shipped in
  the production editor bundle (`static/editor/markdown-editor.js` contains
  lit-html markers). Adopting Lit for our own shell imports the same already-bundled
  module: no new dependency, negligible incremental bytes. This removes the
  usual "is a framework worth the weight" objection -- the weight is already paid.
- **Declarative rendering is a clear win for the view layer.** The toolbar,
  save button, and link editor become a single `render()` template driven by
  reactive state: a `.map` over the command data instead of per-control
  `createElement` + `addEventListener` factories, and `?disabled=${save.buttonDisabled}`
  / `${save.buttonLabel}` / `?hidden=${save.error === null}` bindings instead of
  the imperative `applySaveView` and the save/inline branches of
  `updateToolbarState`. Show/hide of the link popover is a conditional template
  (a ternary on `linkOpen` rendering the popover template or `nothing`) instead
  of `hidden` toggling. The spike's
  whole component is ~200 lines including the command data and handlers; the
  imperative equivalent it replaces is larger and spread across many small
  methods plus a separate update pass.
- **The controllers drop in unchanged.** `SaveStateController` is reused verbatim;
  Lit only changes how its reported view is rendered (`this.save = view;
  requestUpdate()` instead of `applySaveView` poking the DOM). This is exactly the
  separation RFC-0002 set up: state machines stay plain, the view becomes
  declarative. The Tiptap/CodeMirror adapters are untouched.
- **Web Awesome interop is natural at the integration boundary.** `wa-button`,
  `wa-dropdown`, `wa-dropdown-item`, `wa-button-group`, and `wa-icon` are written
  as ordinary tags in the Lit template with attribute and `@click` bindings; the
  spike compiles and bundles cleanly. Rendering into the light DOM
  (`createRenderRoot() { return this; }`) keeps Web Awesome's global control
  styles applying, matching the production light-DOM custom element. (Web Awesome
  controls are themselves `LitElement`s, so they compose as native custom
  elements -- the documented happy path.)
- **Test stability.** The existing vitest suite asserts on rendered DOM
  (`.markdown-editor__*` selectors, button text, `hidden`) and would mostly carry
  over, since Lit renders the same light-DOM structure. A Lit shell re-renders on
  state change rather than mutating in place, so a few tests that poke an element
  then read it back synchronously might need an `await element.updateComplete`;
  that is a small, well-understood adjustment, not a rewrite.

## Recommendation

The objection that previously justified deferral (bundle weight, adding a
framework) is gone: Lit already ships via Web Awesome, and the shell is now
decomposed so Lit would be adopted only for declarative *rendering*, not to
untangle state. On the evidence, Lit is a reasonable adopt-when-convenient, with
the natural trigger still table editing (which adds node-selection controls and
more popover/toolbar state -- precisely where declarative rendering pays most).

Concretely:

- Adopt Lit for the **view layer only**: the toolbar/dropdown/bubble/slash/
  popover rendering and the controllers' reported views. Keep the controllers
  (`SaveStateController`, `ToolbarTooltipController`, `LinkPopoverController`) as
  plain classes and the Tiptap/CodeMirror adapters unchanged.
- Do it as the table-editing increment lands, not as a standalone rewrite, so the
  migration buys immediate new-feature clarity rather than churn for its own sake.
- Before migrating, do one full runtime pass of this spike in the browser to
  confirm Web Awesome control behaviour (dropdown open/close, focus) under Lit's
  re-render; the build-time integration here is clean but runtime focus/slotting
  is worth a direct check.

## Status

Spike complete; it answers the decision test with evidence and supersedes the
"defer Lit" bias in `markdown-editor-spike.md` (the bundle objection no longer
holds). Lit is not adopted in this round -- the recommendation is to adopt it for
the view layer when table editing arrives. The bundle artifact
(`spike/editor-lit/bundle.js`) is gitignored; rebuild with the command above.
