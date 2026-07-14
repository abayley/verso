# Assessment: Adopting React for the Verso Frontend

Status: assessment only, no decision. Written 2026-07-14 in response to the
question: we adopted shadcn component styling (via Basecoat) without the
React-based shadcn/ui components — what would adopting React itself gain
and lose?

## Current Frontend Architecture

Haskell (`Verso.View`) renders complete HTML pages server-side; the client
is Lit components (RFC-0017) wrapping Tiptap and CodeMirror, with Basecoat
supplying the shadcn look as pure CSS plus small vanilla JS behaviours.
There is no client router and no client-side data layer — the server owns
rendering, and the browser enhances it.

## What React Would Gain

- The real shadcn/ui components, i.e. Radix primitives underneath. This is
  the genuine prize: battle-tested focus management, ARIA wiring, keyboard
  navigation, portal/z-index handling, and dismiss behaviour for dialogs,
  dropdowns, popovers, and comboboxes. We currently maintain that by hand —
  the popover transition guard from RFC-0035 is exactly the class of fiddly
  bug Radix has already fixed.
- Declarative state-to-UI for the chrome. The listener-leak discipline we
  had to invent (installers returning uninstall functions) is the sort of
  thing React's component lifecycle makes structurally impossible to get
  wrong.
- Ecosystem gravity: official Tiptap React bindings, React NodeView
  renderers, devtools, an enormous pool of examples — and AI assistants and
  future contributors know React better than Lit.

## What React Would Lose

- The server-rendered architecture, or its coherence. This is the big one.
  React wants to own the DOM it renders. Real SSR for React needs a Node
  runtime — the server is MicroHs; it cannot run React server-side. So we
  would either go SPA (losing fast first paint, curl-able pages, and the
  reading-first design of RFC-0020 where a plain GET returns a readable
  document) or run an islands architecture where Haskell still renders the
  page shell and React mounts into slots. Islands is the only shape that
  fits, and it means two rendering vocabularies forever: `Verso.View` for
  structure, React for behaviour, with the seam between them a permanent
  tax.
- The recent Lit investment. RFC-0017 moved the views to Lit precisely to
  get componentised client code. React re-litigates that decision for a
  modest delta — Lit already gives reactive templates and scoped
  components; React over vanilla JS is a big step, React over Lit is a
  small one.
- Weight and churn. React + ReactDOM is roughly 45KB gzipped before any
  component code, plus Radix per primitive. Against the project's whole
  character — a hand-rolled HTTP server, memchr FFI to save megabytes —
  that is philosophically jarring. shadcn/React/Radix also move fast; we
  would be adopting their upgrade treadmill.
- Neutrality of the hard parts. The genuinely difficult UI in this app is
  the editor, and Tiptap and CodeMirror are framework-agnostic by design.
  React does not help there — React NodeViews add re-render management
  complexity around ProseMirror's own DOM ownership. The 344 editor tests
  and the happy-dom test rig would need migrating for no editor-side gain.

## Net Assessment of Adopting React

The trade is Radix's accessibility and dismiss-behaviour correctness, plus
ecosystem familiarity, in exchange for architectural coherence, bundle
size, the Lit migration, and a permanent Haskell/React rendering seam.
Basecoat exists specifically to deliver shadcn styling without React, and
the hardest components (editor, syntax highlighting, Mermaid) are
framework-neutral anyway, so React would be a large structural cost to
improve the easiest third of the UI.

If the accessibility correctness of dropdowns, popovers, and dialogs ever
becomes a real pain point, the cheaper move is adopting headless non-React
primitives (e.g. Zag.js, or Lit-native equivalents) inside the existing
architecture rather than adopting React wholesale.
