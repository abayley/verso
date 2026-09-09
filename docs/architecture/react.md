# Assessment: Adopting React for the Verso Frontend

Status: assessment only, no decision. Written 2026-07-14 in response to the
question: we adopted shadcn component styling (via Basecoat) without the
React-based shadcn/ui components — what would adopting React itself gain
and lose?

Revisited 2026-09-09, when the question was asked again with the emphasis on
design impact rather than size. The 2026-07-14 sections below are unchanged
apart from two figures marked in place. Everything from
[Measured cost of React and shadcn](#measured-cost-of-react-and-shadcn) onwards
is new, and includes two corrections to assumptions the original made.

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
  component code, plus Radix per primitive. (Measured 2026-09-09 at 61KB
  gzipped for React 19.2.8, and 118KB for the whole shadcn stack; see below.) Against the project's whole
  character — a hand-rolled HTTP server, memchr FFI to save megabytes —
  that is philosophically jarring. shadcn/React/Radix also move fast; we
  would be adopting their upgrade treadmill.
- Neutrality of the hard parts. The genuinely difficult UI in this app is
  the editor, and Tiptap and CodeMirror are framework-agnostic by design.
  React does not help there — React NodeViews add re-render management
  complexity around ProseMirror's own DOM ownership. The 344 editor tests
  (443 as of 2026-09-09) and the happy-dom test rig would need migrating for
  no editor-side gain.

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

## Measured Cost of React and shadcn

Measured 2026-09-09 by installing the packages and bundling them the way
`scripts/build-editor.mjs` does: minified, `NODE_ENV=production`, browser target.
The Radix set matches the component vocabulary the chrome modules expose.

| Stack                             | Raw     | Gzip    | Added over previous row |
| --------------------------------- | ------- | ------- | ----------------------- |
| react and react-dom               | 193,299 | 61,007  |                         |
| plus cva, clsx, tailwind-merge    | 222,060 | 69,817  | 8,810                   |
| plus 8 Radix primitives           | 362,685 | 114,055 | 44,238                  |
| plus 20 lucide icons, tree-shaken | 371,226 | 117,652 | 3,597                   |

The Radix primitives are dropdown-menu, tabs, tooltip, dialog, popover, select,
toggle-group and label. Adding `@tiptap/react` costs about 5,400 bytes gzipped
over `react-dom`, measured with the same Tiptap version in both arms.

Three things would be removed: `basecoat.js` at 10,805 gzipped, `lit` at 5,826,
and `icons.svg` at 1,445, which lucide replaces. The net is about 306KB raw and
100KB gzipped, roughly 18 per cent of the current gzipped first load.

CSS is close to a wash. `basecoat.css` is itself Tailwind output, and a shadcn
setup emits its own Tailwind build for the classes its components use.

## What the Browser Loads Today

| Asset                          | Raw       | Gzip    | Brotli  |
| ------------------------------ | --------- | ------- | ------- |
| markdown-editor.js             | 1,554,910 | 486,627 | 399,795 |
| basecoat.css                   | 222,924   | 21,945  | 17,254  |
| markdown-editor.css            | 178,683   | 42,400  | 35,211  |
| basecoat.js                    | 43,909    | 10,817  | 9,505   |
| roboto.css and roboto-mono.css | 7,378     | 2,041   | 1,534   |
| appearance-bootstrap.js        | 2,235     | 978     | 791     |
| First load total               | 2,010,039 | 564,693 | 464,090 |

`mermaid.js` is not in that total: at 3,492,132 bytes raw it is the largest
artefact in the tree and is loaded on demand only when a page contains a diagram
(RFC-0033, ADR-0071). Web fonts add 365,628 bytes on disk, of which a browser
fetches only the subsets its `unicode-range` rules select.

Bundled alone, the editor engines dominate everything else: codemirror with
lang-markdown at 209,834 gzipped, tiptap core and starter-kit at 128,610,
tiptap extension-table at 93,896, tiptap markdown at 67,527, lowlight at 53,572,
unified and remark at 35,170. Lit, the piece React would replace, is 5,826 —
the smallest item on the list.

Verso sends no `Content-Encoding`: a request carrying `Accept-Encoding: gzip, br`
returns `Content-Length: 1554910` for the bundle. The intention is to front Verso
with nginx for TLS, compression and static file serving, which settles this
outside the application.

## Client-Side Compute Measured at Page Load

A devtools trace of a document page load, on a fast machine against a local
server: EvaluateScript 93.2ms, v8.run 92.8ms, Layout 48.3ms, UpdateLayoutTree
36.5ms, RasterTask 32.4ms, ParseHTML 10.1ms, FunctionCall 5.7ms, v8.compile
0.3ms. `domContentLoaded` 187ms, `load` 310ms, 2,083,437 bytes transferred.

Script evaluation is about 93ms for 1.55MB of JavaScript. React adds roughly 20
per cent to the byte count, so on the order of 15 to 20ms more evaluation on this
hardware and proportionally more on a slow phone. The work that costs during
editing is ProseMirror, CodeMirror and remark handling the document, and none of
that changes. Compute is not a reason to decide either way.

## Correction: What Actually Works Without JavaScript

The 2026-07-14 assessment said React would lose "curl-able pages, and the
reading-first design of RFC-0020 where a plain GET returns a readable document".
Measurement does not support that.

A document page fetched with no JavaScript is 5,666 bytes. It contains a
`<textarea>` holding the raw Markdown including its frontmatter, and a
`<noscript>` Save button. It contains no rendered headings and no chrome, and
there is no server-side Markdown rendering anywhere in `src/Verso/*.hs`. Without
JavaScript a reader gets the document's source in a text box, not a readable
document.

The document view's chrome is built on the client. The server-rendered chrome
call sites in `View.hs` belong to `searchPage`, `trashPage`, `trashRow`,
`undoRow` and `revisionRow` — the ancillary pages. Those do work without
JavaScript and would stop doing so under React unless rendered another way.

So the no-JavaScript surface genuinely at risk is four ancillary pages. It is not
the editor, which has no meaningful no-JavaScript behaviour to lose, and it is
not the `<textarea>` fallback, which is Haskell-rendered HTML independent of
whatever runs on the client. The islands-tax argument in the original still
stands; the reading-first argument does not.

## The Chrome Vocabulary Is Implemented Three Times

This was found by reading the code in 2026-09-09 and is the strongest design
argument on the pro-React side. The same button, icon, dropdown and tabs
vocabulary exists three times:

1. `Chrome.hs`, 136 lines of Haskell, for the server-rendered ancillary pages.
2. Lit template builders in `chrome.ts`: `chromeButton`, `chromeIcon`,
   `chromeDropdown`, `chromeTabs`, returning `TemplateResult`.
3. Imperative DOM builders in the same file: `chromeButtonEl`, `chromeLinkEl`,
   `chromeIconEl`, `chromePanelHeadingEl`, `chromeAlertEl`, `chromeSegmentEl`,
   `chromeDropdownEl`, returning elements.

All three emit the same `btn` class with `data-variant` and `data-size`
attributes. `chrome.ts` is 698 lines, most of it that duplication. The split
exists because the client is not written in one style: Lit is used in 6 of the
editor's source files, while 19 use `document.createElement` directly.

React would collapse arms 2 and 3 into one component set. It would not remove
arm 1, so the duplication reduces from three implementations to two, not to one.

## The Largest Complexity Is Not Caused by the View Layer

`markdown-editor-element.ts` is 2,405 lines. It extends `HTMLElement` rather than
`LitElement`, and holds 57 fields and 114 methods, coordinating the Tiptap visual
editor, the CodeMirror source editor, the navigation tree, the panels and the
save lifecycle. The editor sources are 15,002 lines in total, so this one file is
16 per cent of them.

Much of what a large imperative element does is keep the DOM in step with state
by hand, which is what React's model removes, and that is a real argument for
React. But this file's size comes from the number of responsibilities it holds,
not from the absence of a framework. Splitting those responsibilities is
available today and would help whatever view layer sits underneath.

## Revised Net Assessment After the 2026-09-09 Measurements

The measurements moved three things and left the 2026-07-14 conclusion mostly
intact.

Weaker than the original argued: the reading-first and curl-able-pages defence,
which measurement does not support, and bundle weight, which at 18 per cent of a
payload already dominated by editor engines is not a deciding factor. The "large
structural cost to improve the easiest third of the UI" framing also understates
one thing, now that the three-way chrome duplication is visible: that easiest
third is currently paid for three times over.

Stronger than the original argued: React does not help the editor. The compute
measurement confirms the hard work is ProseMirror, CodeMirror and remark, and
React node views add reconciliation around ProseMirror's own DOM ownership in the
one part of the application that carries the product's value.

The revised position is net positive for the interface shell and risky for the
editor core. If it is pursued, the sensible scope is the shell and the chrome —
panels, toolbars, floating surfaces, ancillary pages — leaving the ProseMirror
node views alone. That takes the duplication and accessibility wins, keeps the
risk away from the editing surface, and reduces the no-JavaScript loss to four
pages rather than the whole application.

If it is not pursued, the original's suggestion of headless non-React primitives
still stands, and the duplication in `chrome.ts` is worth removing on its own
terms by choosing one client style instead of two.
