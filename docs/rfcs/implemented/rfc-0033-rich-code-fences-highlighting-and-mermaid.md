---
id: RFC-0033
name: Rich code fences — syntax highlighting and Mermaid diagrams
status: Implemented
owners:
    - alistairbayley
created: 2026-07-01
updated: 2026-07-02
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Rich code fences — syntax highlighting and Mermaid diagrams

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-07-01       |
| Started   | 2026-07-02       |
| Completed | 2026-07-02       |

## Summary

Two enhancements to fenced code blocks in the visual editor, delivered as one
change because they share the code-block node, the read/edit render path, and the
bundle-delivery question. First, fenced code blocks gain **syntax highlighting**
for a curated set of languages, themed by the editor palette so they read well in
every visual theme. Second, a fence whose language is `mermaid` renders as a
**diagram** in the read view and as editable source-with-live-preview while
editing. Both are portable: nothing changes on disk — a highlighted block and a
Mermaid diagram are ordinary ```` ```lang ```` fences in the Markdown — and both
are implemented entirely client-side in the Tiptap visual editor.

## Context

Rendering in Verso is entirely client-side. The Haskell server serves the raw
Markdown inside a `<textarea name="markdown">` within the `<markdown-editor>`
element (RFC-0001 progressive enhancement); the Tiptap visual editor renders it
for both the edit view and the read view (the read view is the same component with
`data-readonly`, RFC-0020). There is no server-side Markdown-to-HTML step, so both
features are client-side editor work with no Haskell rendering changes.

Today fenced code blocks use Tiptap StarterKit's default `codeBlock` node: a plain
monospace block with no language colouring. (The CodeMirror *source* editor already
theme-highlights Markdown syntax, but it does not highlight the language *inside* a
fence, and it is a separate surface.) Mermaid is not supported at all — a
```` ```mermaid ```` fence shows its source as a plain code block.

The editor ships as a single minified IIFE bundle (`static/editor/markdown-editor.js`,
built by `Bun.build`, no code-splitting). Syntax-highlighting data (highlight.js
language grammars) is modest; Mermaid is very large (hundreds of KB parsed), so its
delivery is the main architectural question this RFC resolves.

Decisions already taken with the reviewer (see Alternatives Considered for the
rejected options):

- One combined RFC (this document), phased.
- Mermaid is delivered as a **separately built, lazily loaded** bundle.
- Syntax highlighting covers a **curated subset** of languages.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark it
as complete in the phase checklist.

## Goals

- Fenced code blocks are syntax-highlighted for a curated set of common languages,
  in both the edit and read views, themed by the editor palette.
- A ```` ```mermaid ```` fence renders as a diagram in the read view, and as
  editable source with a live preview (and legible errors) while editing.
- Both features preserve the editor's **round-trip stability** contract: neither
  introduces any new serialization divergence for code blocks. The serializer already
  reads a code block's text via `textContent` (so highlight token spans are
  invisible to it) and its language from the `language-` class, and already
  normalizes fences (three backticks; only a `language`, no info-string `meta`) —
  this RFC inherits that behaviour unchanged rather than adding to it.
- The base editor download is not materially heavier for the common case of pages
  with no Mermaid diagrams.
- Unknown or unsupported fence languages degrade gracefully to a plain code block.

## Non-Goals

- Highlighting embedded fence languages inside the CodeMirror Markdown *source*
  editor (nested-language highlighting in CodeMirror is a separate, harder feature).
- Server-side (Haskell) rendering of Markdown, highlighting, or diagrams.
- Diagram formats other than Mermaid (PlantUML, Graphviz, etc.).
- Editing Mermaid diagrams by direct manipulation; the source text remains the
  single source of truth.
- Exporting diagrams to standalone image files, or embedding rendered SVG in the
  saved Markdown.
- A full highlight.js language set (see Alternatives Considered).

## Proposal

### Shared groundwork: the code-block node view

Both features hang off the fenced-code-block node. StarterKit's `codeBlock` is
disabled (`StarterKit.configure({ codeBlock: false, ... })`) and replaced by a
custom code-block extension registered alongside the existing custom nodes
(`Admonition`, `Collapsible`, `Badge`, ...) in
[tiptap-visual-editor.ts](../../src/Verso/Editor/tiptap-visual-editor.ts). The node
keeps the standard code-block schema (a `language` attribute, a text-only body), so
`@tiptap/markdown` serialises it back to a ```` ```lang ```` fence unchanged — the
content model and on-disk form are untouched.

The node's rendering branches on the `language` attribute:

- `language !== "mermaid"` → a highlighted code block (Phase 1).
- `language === "mermaid"` → a Mermaid node view (Phase 2).

This branch lives in one place so the read/edit toggle (`editable`) and theming are
shared.

### Phase 1 — syntax highlighting

Use `@tiptap/extension-code-block-lowlight` with `lowlight` (the ProseMirror-native
wrapper over highlight.js). Lowlight tokenises the code-block body and emits
`hljs-*`-classed decoration spans; no HTML is injected into the document model, so
serialisation is unaffected.

- **Language coverage.** Register a curated subset (~15–25) of common languages at
  bundle time: js/ts/tsx, python, bash/shell, json, yaml, toml, html/xml, css,
  sql, rust, go, haskell, markdown, diff, dockerfile, ini. The exact list is an
  Open Question. Unregistered languages fall back to an unhighlighted block (no
  error).
- **Theming.** Highlighting is driven by CSS, not a bundled highlight.js theme: a
  new block in [markdown-editor.css](../../static/editor/markdown-editor.css) maps
  the `hljs-*` token classes (keyword, string, comment, number, function, etc.) to
  the editor palette variables (`--markdown-editor-*`), mirroring how the CodeMirror
  source editor's `paletteHighlightStyle` already colours Markdown tokens. This
  keeps colours consistent across all five visual themes and the light/dark scheme,
  with no per-theme highlight themes to maintain.
- **Language affordance (the single control).** In the Markdown view an author types
  the info string directly; in the Visual view they cannot (the caret is inside the
  block), so the code-block node carries a compact language picker — a `wa-dropdown`
  matching the toolbar controls, shown while editing in all themes — that sets the
  `language` attribute. Its entries are the curated highlight languages **plus
  `mermaid`**: picking a highlight language colours the block; picking `mermaid` is
  exactly what flips the node into diagram mode (Phase 2). One control, no
  special-casing. In the read view the language shows as a small muted label. The
  existing `/`-menu "Code block" entry still inserts a plain (no-language) block.
  (Minimum viable: fences typed as ```` ```lang ```` in source highlight on load; the
  picker is the Visual-view path to the same.)

### Phase 2 — Mermaid diagrams

A code block with `language === "mermaid"` gets a custom node view that renders the
diagram, and reveals the editable source only while the author is editing that node
(there is no separate preview surface — the glossary forbids "preview"):

- **Read view (`!editable`).** Render only the diagram (Mermaid-produced SVG). Source
  is never shown.
- **Visual view (editable), node not focused.** Render the diagram, exactly as the
  read view — the Visual view stays WYSIWYG.
- **Visual view (editable), node focused.** Swap the diagram for the editable fence
  source (as for any code block); on blur, re-render the diagram from the new source.
  If Mermaid fails to parse, the node shows a legible error (Mermaid's message) in
  place of the diagram and the source stays editable — an invalid diagram never
  blocks editing or loses text.
- **Portability / serialisation.** The node stays the ordinary code-block node with
  `language: "mermaid"`, and its NodeView keeps the code-block DOM shape: a `<pre>`
  root containing a `<code class="language-mermaid">` holding the source (visually
  hidden while the diagram shows) plus the rendered diagram element. So the existing
  `codeBlockFromElement` serialiser (which keys on `tagName === "PRE"` and reads
  `code.textContent`) round-trips it to a ```` ```mermaid ```` fence with no new
  serialiser code — the diagram is non-serialised chrome, and no SVG reaches disk.
  This is why the source `<code>` must remain in the DOM even when hidden (Q2).

**Lazy delivery.** Mermaid is built as a *second* Bun entrypoint,
`static/editor/mermaid.js` (its own IIFE, exposing a single init/render function on
a namespaced global, e.g. `window.__versoMermaid`). The main editor bundle does not
import Mermaid; instead, the first time a Mermaid node needs rendering, the editor
injects a `<script src="/static/editor/mermaid.js">` (same origin, so allowed), and
caches the load promise so it loads once per page. Pages with no Mermaid fence never
download it. `scripts/build-editor.mjs` gains a second build call for this
entrypoint; the existing static handler serves the file with no App.hs change.

**Mermaid configuration.** Initialise Mermaid with `startOnLoad: false` and
`securityLevel: "strict"` (Mermaid bundles DOMPurify and, at strict level, avoids
`eval`/inline handlers and sanitises output). Each render targets an isolated
container; the editor pages set no restrictive CSP (only attachment downloads do,
RFC-0018), so Mermaid's SVG and injected styles are not blocked.

**Theme follows the scheme live.** Mermaid bakes its theme into the SVG at render
time, but the appearance control flips light/dark live (it toggles `wa-dark`/
`wa-light` on `<html>` without reloading). So the editor re-renders the visible
Mermaid diagrams when the colour scheme changes, using the matching Mermaid theme,
debounced and bounded by the diagrams actually in the open document. Diagrams always
match the page.

### What does not change

- On-disk Markdown, the content model (`editor-model.ts`), and the remark
  parse/serialise seam.
- The Haskell server, except that it already serves `static/editor/*` (so the new
  `mermaid.js` is served with no code change).
- The CodeMirror source editor.

## Alternatives Considered

- **Two separate RFCs (highlighting, Mermaid).** More modular, but the two share the
  code-block node view, the read/edit render toggle, theming, and the bundle
  question; splitting them scatters those decisions. Rejected in favour of one phased
  RFC.
- **Bundle Mermaid inline in the main editor bundle.** Simplest build, but every
  editor and read page — the vast majority with no diagrams — would pay the large
  download and parse cost. Rejected in favour of a lazily loaded separate bundle.
- **Full highlight.js language set (~190).** Comprehensive but a very large bundle
  addition for a docs wiki. The `common` (~35) preset is a middle option; a curated
  subset was chosen to keep the base bundle lean, with graceful fallback for the
  long tail.
- **Server-side rendering (Haskell) of highlighting/diagrams.** Would duplicate the
  rendering that the client already owns, add heavy dependencies to the MicroHs
  server, and diverge the read and edit views. Rejected; rendering stays client-side.
- **Prism / Shiki instead of lowlight.** Shiki produces excellent output but is
  heavy and async and does not integrate with ProseMirror decorations as cleanly;
  Prism lacks a maintained ProseMirror binding. Lowlight is the ProseMirror-native
  fit and reuses the palette-driven CSS approach already in the codebase.
- **CodeMirror node views for code blocks** (embedding CodeMirror inside each fence).
  Powerful, but far heavier per block and redundant with lowlight for read-mostly
  content. Rejected.

## Security Impact

- Mermaid renders author-supplied text into SVG. It is initialised with
  `securityLevel: "strict"` and its bundled DOMPurify, so scripts and inline event
  handlers in diagram source are stripped. This must be verified in the spike.
- No new network origins: both the highlight grammars and the Mermaid bundle are
  served from the app's own origin under `/static/editor/`. No CDN or external fetch.
- Highlighting adds only decoration spans over existing text; it introduces no new
  HTML sink.
- No authentication/authorization surface is touched.

## Reliability Impact

- **Unknown languages / invalid Mermaid.** Both degrade gracefully: an unregistered
  language renders as a plain code block; an unparseable Mermaid diagram shows an
  error and keeps the source editable. Neither loses document text.
- **Lazy-load failure.** If `mermaid.js` fails to load, the node falls back to
  showing the fence as a plain code block with a one-line notice; the rest of the
  page is unaffected.
- **Observability, and the telemetry boundary.** Two failure kinds are handled
  differently. A diagram **syntax error** (the author's Mermaid source does not
  parse) is expected authoring feedback: shown inline in the node only, and *never*
  sent to the client-error sink — it is normal user input and its message can contain
  page content, which the **client-error report** contract forbids. A **bundle-load
  or render-engine failure** is a real defect: reported to the client-error sink
  (RFC-0023) with only a generic reason (no diagram source), with the plain-code-block
  fallback above.
- **Round-trip safety.** The strongest guarantee: because neither feature changes the
  content model, an untouched document round-trips byte-for-byte; this is covered by
  serialisation tests.

## Compatibility Impact

- Fully backward compatible on disk: existing ```` ```lang ```` and
  ```` ```mermaid ```` fences simply start highlighting / rendering; no migration.
- No change to the application stream contract, routes, or config keys.
- A new served asset (`static/editor/mermaid.js`) and a larger main bundle (by the
  curated highlight grammars). No external API/adapter impact.

## Testing and Quality Gates

- `make editor-check` (bun lint/typecheck/test/build) and `make check`.
- Unit (vitest): ```` ```lang ```` ↔ code-block-with-language round-trips; highlight
  decorations are produced for a registered language and absent for an unknown one;
  a ```` ```mermaid ```` fence parses to a code block with `language: "mermaid"` and
  serialises back unchanged.
- Browser (`make test-editor-browser`, Playwright): Mermaid actually renders to SVG
  in the read view and updates live while editing; invalid source shows an error.
  Rationale: Mermaid rendering (and, like the badge mark, any canvas/SVG measurement)
  does not run under jsdom/happy-dom, so diagram rendering is verified in a real
  browser, not the vitest suite. (See [[rfc-0032-git-versioning]] for the jsdom
  canvas gotcha.)
- Manual: `make run-verso`, confirm highlighting across all five themes in light and
  dark, and a Mermaid diagram in read vs edit.

## Rollout Plan

1. **Shared groundwork.** Swap StarterKit's `codeBlock` for the custom code-block
   extension; confirm existing plain code blocks still round-trip (regression gate
   before adding behaviour).
2. **Phase 1 — highlighting.** Add lowlight with the curated language set; add the
   palette-driven `hljs-*` CSS; add the language label/picker. Tests + theme sweep.
3. **Spike — Mermaid delivery.** Prove the second-entrypoint build, the on-demand
   `<script>` load, and `securityLevel: "strict"` rendering in a browser before
   committing to the node view. Record findings here.
4. **Phase 2 — Mermaid.** Add the Mermaid node view (read = diagram, edit =
   source + live preview + errors), wired to the lazy loader. Browser tests.
5. **Docs.** Done during design: `CONTEXT.md` gains the **Mermaid diagram** term and
   ADR-071 records the lazily-loaded-separate-bundle and Mermaid-as-code-block
   decisions. Mermaid's version is pinned exactly (deliberate, reviewed upgrades).

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do not
  cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if
  another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user approval.

## Open Questions

- The exact curated language list, and whether it is trivially extensible (a single
  array) so adding a language later is a one-line change.
- Confirm `@tiptap/extension-code-block-lowlight` renders `<code>` with the default
  `language-<lang>` class prefix that `codeLanguage()` reads, so the marked load path
  and the DOM serialise path agree on the language (resolve in the Phase 1 spike).
  Serialisation itself is already settled: it goes through `codeBlockFromElement`
  (DOM `textContent` + `language-` class), not `@tiptap/markdown`.
- Focus granularity for the Visual-view source/diagram swap: does the source appear
  on node selection, on caret-inside, or on an explicit "edit" affordance — and how
  is a keyboard-only author expected to enter and leave the source?
- Placeholder content for the Studio `/`-menu "Mermaid diagram" insert: implemented
  as `flowchart TD\n    A[Start] --> B[End]`.
- Follow-up: a Mermaid bundle-load/engine failure currently shows an inline notice
  and keeps the source editable, but is not yet routed to the client-error sink
  (RFC-0023) as the Reliability section intends; wiring it through the editor's error
  boundary is deferred (syntax errors correctly stay inline-only).
