---
id: RFC-0017
name: Editor Content Extensions
status: Draft
owners:
    - alistair
created: 2026-06-16
updated: 2026-06-16
supersedes: []
superseded_by: null
---

# Editor Content Extensions

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-16       |
| Started   | 2026-06-16       |
| Completed |                  |

## Summary

Introduce an editor *content extension* mechanism so new block and inline types
are added as self-contained modules registered at each pipeline seam, rather than
by editing every core file. Land four initial extensions on it: GFM tables, GFM
admonitions (`> [!NOTE]` alerts), mkdocs-material collapsible sections, and
footnotes. The mechanism is the deliverable; the four features are its first
clients and the proof it works -- spanning block (tables, collapsibles),
blockquote-decoration (admonitions), and inline-plus-document-level (footnotes)
shapes. This is the table-editing increment the Lit decision-test spike named as
the point to adopt Lit for the editor's view layer.

## Context

A Markdown feature in this editor is not one change; it threads through several
representations and a closed, exhaustive switch in each, every one of which
throws on an unknown type. Adding one block type today edits all of:

1. `editor-model.ts` -- the closed `EditorBlock` / `InlineNode` unions.
2. `remark-adapter.ts` -- mdast node to editor block (the parse path; the right
   remark plugin must also produce the mdast node).
3. `markdown-render.ts` -- editor block to HTML (preview and mode-switch
   validation, browser-owned per ADR-019/ADR-040).
4. `markdown-serialise.ts` -- two functions: DOM element to editor block (reading
   Tiptap's rendered DOM) and editor block to Markdown text.
5. `tiptap-visual-editor.ts` -- the Tiptap node/extension, its commands, and the
   `@tiptap/markdown` load path.
6. The toolbar / slash-menu UI and the block-command routing in
   `markdown-editor-element.ts`.
7. `MicroHttp.TestApp` (Haskell) -- the `supportedBlock` save-time validation
   guard (ADR-040), which rejects Markdown outside the editor's subset.
8. CodeMirror source mode, when the syntax is exotic enough to need highlighting.

So features added ad hoc mean scattered edits across six TypeScript files plus
the Haskell guard, once per feature, with no shared structure; and "arbitrary
extensions" -- the actual goal -- is impossible without editing core files for
each one. The closed unions and `throw unsupportedNode(...)` defaults
are the obstacle.

Two enablers are already in place. `remark-gfm` is a dependency, so GFM tables
and strikethrough already parse to mdast. RFC-0002 decomposed the editor shell
into controllers, and the Lit decision-test spike (`docs/design/editor-lit-spike.md`)
recommended adopting Lit for the view layer "when table editing arrives" -- which
is now. Lit is already shipped via Web Awesome, so its view-layer use is free.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- A content-extension registry: each extension is one module that registers
  handlers for the seams it needs (parse, model, render, serialise-in,
  serialise-out, Tiptap node, commands), and the core pipeline iterates the
  registry instead of hardcoding each type. The registry covers block *and*
  inline extensions (footnotes need both).
- Open the closed model: an editor block/inline can be an extension-defined type
  carried generically, so adding a type does not edit `editor-model.ts`.
- Four extensions shipped on the mechanism: GFM tables, GFM admonitions,
  mkdocs-material collapsibles, and footnotes.
- A coherent answer for the Haskell save-time guard under an open, client-defined
  subset (it cannot track arbitrary extensions across the language boundary).
- Graceful degradation: an extension's Markdown should remain readable (ideally
  valid GFM) when an extension is absent or scripting is off (ADR-040: no-JS
  reading is raw Markdown).

## Non-Goals

- Not a general CMS or plugin marketplace; extensions are code-defined and
  in-tree, not user-authored or runtime-loaded.
- No server-side Markdown rendering; rendering stays browser-owned (ADR-040). The
  server guard is validation only.
- No arbitrary raw HTML; it stays uniformly rejected. Collapsibles use mkdocs
  syntax, not `<details>`, so no allowlist exception is introduced.
- Not every conceivable block; the registry is the contract, and the four
  features plus the existing subset are this RFC's deliverable.

## Proposal

### The extension contract

A content extension is a TypeScript module implementing a registration interface,
collected into a registry the pipeline consults. Sketch:

```ts
interface ContentExtension {
    name: string;
    // Parse: remark plugins to install, and mdast -> editor block/inline.
    remarkPlugins?: Pluggable[];
    fromMdast?(node: unknown, ctx: ParseContext): EditorNode | null;
    // Render (preview/validation): editor node -> HTML chunks.
    renderNode?(node: EditorNode, ctx: RenderContext): string | null;
    // Serialise: Tiptap DOM -> editor node, and editor node -> Markdown.
    fromElement?(element: Element, ctx: SerialiseContext): EditorNode | null;
    toMarkdown?(node: EditorNode, ctx: SerialiseContext): string | null;
    // Edit: Tiptap node/mark extensions and the commands/UI entries.
    tiptapExtensions?: Extension[];
    commands?: EditorCommand[];
}
```

The closed dispatchers become registry walks: `blockFromMdast`,
`renderBlock`, `blockFromElement`, and `blockToMarkdown` try each extension's
handler in turn and fall back to the built-in subset, instead of a hardcoded
`if`-chain that throws. The built-in types (heading, paragraph, list, blockquote,
code, hr, the inline marks) are reframed as the always-present base extension, so
there is one mechanism, not a special case plus extensions.

### Opening the model

`editor-model.ts`'s unions gain an extension-carried variant so an
extension-defined block does not require editing the union:

```ts
interface CustomBlock {
    type: "custom";
    extension: string;     // registry key
    data: unknown;         // extension-owned payload (validated by the extension)
    children?: EditorBlock[];
}
```

Built-in types keep their concrete shapes (no churn to existing code paths);
extensions use `CustomBlock`/`CustomInline`. The render/serialise walks dispatch a
`custom` node to its owning extension by `extension`.

### The initial extensions

- **GFM tables.** `remark-gfm` already yields `table`/`tableRow`/`tableCell`
  mdast, so the parse half exists. The extension adds: a model mapping,
  `renderNode` to `<table>` HTML, `@tiptap/extension-table` (+ row/cell/header --
  a new dependency) for editing, a DOM `TABLE` -> Markdown pipe-table serialiser,
  and a slash-menu "Table" insert. Portable GFM; degrades to a readable pipe
  table without scripting.
- **GFM admonitions (alerts).** GitHub alerts are a blockquote whose first line is
  `[!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` / `[!CAUTION]`. They are
  already valid blockquotes -- the existing blockquote path accepts them today and
  they render as plain blockquotes. The extension *recognises* the marker on a
  blockquote and styles it as an alert (render + a Tiptap node decoration), with a
  slash entry. This is the cheapest extension and the best degradation: absent the
  extension it is a normal blockquote, and it matches GitHub rendering.
- **Collapsible sections.** Use the mkdocs-material collapsible-admonition
  syntax: `??? type` (collapsed by default) and `???+ type` (collapsible but open
  by default), with an optional `"Title"` and the body indented four spaces:

  ```text
  ??? note "Optional title"

      Indented body content.
  ```

  This is deliberately a different callout family from the GFM-alert admonitions
  above (decided: admonitions stay GFM-portable, collapsibles use mkdocs), but the
  two share rendered callout chrome (icon, type colour, title bar). The extension
  adds: a custom parser (see below), a model mapping, `renderNode` to a
  collapsible callout, a custom Tiptap collapsible node (Tiptap's `Details` is a
  Pro extension; a small custom node avoids that dependency), the toggle UI, and a
  slash entry. The collapsed/open default is carried in the model and round-trips
  as `???` versus `???+`.

  Parsing is the main risk. The mkdocs/Python-Markdown grammar is not CommonMark
  and not covered by `remark-gfm`; worse, CommonMark reads the four-space-indented
  body as an indented code block, so a custom micromark construct (plus its
  mdast-util) is needed to claim the indented body for the callout. No
  well-maintained off-the-shelf remark plugin covers the exact mkdocs syntax, so
  treat this as a from-scratch parser extension with its own focused tests.
- **Footnotes.** Not CommonMark, but `remark-gfm` (already a dependency) parses
  the GitHub syntax -- `[^id]` inline references and `[^id]: ...` block
  definitions -- into mdast `footnoteReference` / `footnoteDefinition`. The editor
  pipeline does not handle them today (the remark adapter throws on those nodes),
  so they are a full extension, and the most complex: an *inline* reference node
  plus a *document-level* set of definitions, with numbering, a collected
  definitions list, and back-links. Footnotes are the reason the mechanism must
  support inline extensions, not only block ones, and the reason the model needs a
  `CustomInline` variant alongside `CustomBlock`. The extension adds: the
  reference/definition model, render (superscript reference linking to a collected
  ordered list), a Tiptap inline reference node and definition handling (a
  community footnote extension or a custom node; to be chosen during the phase),
  and a serialiser preserving the `[^id]` labels and definitions. Footnotes are
  portable GFM and degrade to plain `[^id]` text.

### Native syntaxes, not a uniform directive

All four extensions use native syntaxes -- GFM pipe tables, GFM alerts, GFM
footnotes, and mkdocs collapsibles -- rather than a single uniform directive
grammar (`:::name`). The trade-off accepted: there is no one parser serving every
extension, so each extension brings its own remark/micromark parsing; in exchange
tables and admonitions stay portable GFM and degrade gracefully, and collapsibles
match the mkdocs syntax the team uses. The registry still abstracts over "how this
extension parses", so the lack of a shared grammar costs only parser code per
extension, not a structural change. The mkdocs callout parser, once written, is
reusable for a family of callout types if more are added.

Degradation: a `??? note` block read by a renderer without the extension shows
the body as a code block (poor) -- but for this project that does not arise on the
no-JavaScript path, where ADR-040 serves *raw* Markdown (readable source), not
rendered HTML. The degradation cost is portability to other renderers, not the
local fallback.

### The Haskell save-time guard under an open subset

`supportedBlock` (ADR-040) validates posted Markdown against a hardcoded subset.
With a client-extensible, open subset, keeping the Haskell recogniser in sync is
the cross-language dual-implementation trap ADR-040 rejected for rendering.
Decided: narrow the server guard to its security purpose -- keep raw-HTML
rejection -- and drop the block-structure validation entirely. The editor becomes
the authority on its own (now open) subset; the server defends the trust
boundary, not the grammar. This is the ADR-040 framing carried to its conclusion
and gets a short ADR. No raw-HTML allowlist is needed: collapsibles use mkdocs
syntax, not `<details>`, so raw HTML stays uniformly rejected.

### Lit for the extension views

Decided (per the Lit spike): adopt Lit for the *view layer* of the new extensions
(table cell controls, admonition chrome, collapsible toggle) and the existing
toolbar/popover rendering, while the controllers, the extension registry, and the
Tiptap/CodeMirror adapters stay framework-agnostic. Tables especially add
node-selection toolbars and per-cell state where declarative rendering pays off.
Lit ships already via Web Awesome, so this is no new dependency. It lands with the
table phase (the spike's "when table editing arrives" trigger).

## Alternatives Considered

- **Add the four features ad hoc, no registry.** Fastest for exactly four, but it
  multiplies the scattered-edit problem and leaves arbitrary extensions
  impossible -- the explicit goal. Rejected.
- **Use `@tiptap/markdown` round-trip for everything (drop the custom
  serialiser).** Tempting, but the out-path is the custom DOM-walk serialiser by
  design (control over the exact Markdown subset emitted); replacing it is a
  larger, riskier change orthogonal to extensions. Out of scope.
- **Raw HTML (`<details>`) for collapsibles, or a uniform `remark-directive`
  (`:::`) grammar for all extensions.** `<details>` is GitHub-portable but reopens
  the raw-HTML trust hole ADR-040 closed; directives give one parser for every
  extension but a non-portable syntax. Both rejected in favour of native syntaxes
  per feature (decided): tables/alerts stay portable GFM, collapsibles use the
  mkdocs `???` syntax the team uses, raw HTML stays banned.
- **Keep the Haskell subset validation in lockstep with extensions.** The
  cross-language sync trap; rejected for the same reason ADR-040 rejected a server
  renderer.

## Security Impact

- Raw HTML stays uniformly rejected. None of the new syntaxes (pipe tables, GFM
  alerts, GFM footnotes, mkdocs `???`) is raw HTML, so no allowlist exception is introduced; the
  mkdocs callout parser produces editor nodes, not HTML, and their text is escaped
  by the same render path as other content.
- Narrowing the server guard to raw-HTML rejection preserves the trust boundary
  (the server still never trusts client Markdown to be safe) while ceding grammar
  authority to the editor.

## Reliability Impact

- Each extension is isolated: a malformed or absent extension degrades to the
  base subset (an unknown `custom` block with no handler renders as its raw
  Markdown / is skipped, not a thrown exception that breaks the whole document).
  The registry walks must fail soft, unlike today's throwing defaults.
- Round-trip fidelity (Markdown -> edit -> Markdown) must hold per extension; this
  is the main correctness risk and is covered by per-extension golden tests.

## Compatibility Impact

- New dependencies: `@tiptap/extension-table` (+ row/cell/header) and `lit` used
  directly (already transitively present via Web Awesome). Collapsibles use a
  custom mkdocs-syntax micromark/remark extension and a custom Tiptap collapsible
  node (no Tiptap Pro), so they add code rather than a third-party runtime dep.
- The Markdown subset grows; documents using the new syntax are still valid GFM
  for tables and alerts, while mkdocs `???` collapsibles are non-GFM (their body
  shows as a code block in renderers without the extension; immaterial to the
  no-JavaScript path, which serves raw Markdown).
- The Haskell guard change is a behaviour change (it will accept more); covered by
  `MicroHttp.TestApp` tests.
- The extension refactor of the core dispatchers must keep the existing subset
  byte-identical through the registry (the `HtmlSpec`/editor golden tests pin
  this).

## Testing and Quality Gates

- `make check` green after each phase; `make test-editor-browser` after the
  feature phases.
- Registry refactor: existing editor unit tests and Markdown round-trip tests
  pass unmodified (the base subset routed through the registry is unchanged).
- Per extension: parse, render, DOM-serialise, and Markdown round-trip golden
  tests, plus a browser smoke interaction (insert a table and edit a cell; toggle
  an admonition type; open/close a collapsible) and a degradation test (the raw
  Markdown a no-extension/no-JS reader sees).
- `MicroHttp.TestApp` tests for the narrowed guard (raw HTML still rejected; the
  new syntaxes accepted; `<details>` allowlist if chosen).

## Rollout Plan

1. Phase one: the extension mechanism (no new features).
   - [x] Introduce the `ContentExtension` interface, the registry, and the
         `CustomBlock` / `CustomInline` model variants; convert the core
         dispatchers (`blockFromMdast`, `inlineNodeFromMdast`, `renderBlock`,
         `renderInlineNode`, `blockFromElement`, `blockToMarkdown`) to registry
         walks with fail-soft fallbacks; reframe the built-in subset as the base
         extension. The registry covers block and inline extensions. Existing
         tests pass unmodified.

     Implemented in `content-extension.ts` (the mechanism: the
     `ContentExtension` interface, the per-seam context interfaces,
     `registerExtension` with a `fallback` flag, and the six registry-walk
     dispatchers) and `base-extension.ts` (the built-in subset consolidated as
     the fallback extension, registered via `registerExtension(..., { fallback:
     true })`). `editor-model.ts` gained the `CustomBlock` / `CustomInline`
     union members. `remark-adapter.ts`, `markdown-render.ts`, and
     `markdown-serialise.ts` are now thin public-API wrappers over the registry
     walks. Decisions taken this phase:
     - Parse seams (`blockFromMdast`, `inlineFromMdast`) stay *strict*: a node
       no extension claims throws `unsupportedNode`, preserving the raw-HTML
       rejection guard the existing tests pin. Render and serialise seams fail
       soft (skip / empty / paragraph fallback). This keeps the base subset
       byte-identical while opening the model.
     - The built-in handler logic was consolidated into `base-extension.ts`
       (one module per the RFC), not left scattered in the three pipeline
       files; imports stay acyclic (pipeline -> {content-extension,
       base-extension}; base-extension -> content-extension).
     - `CustomBlock` / `CustomInline` are non-exported union members for now
       (matching the other block interfaces); a later phase exports them when
       an extension references the type by name. `registerExtension` is
       exported now and exercised by the base extension's fallback
       registration.
     - `remarkPlugins` and the Tiptap/command seams from the interface sketch
       are deferred to the phases that first need them, to avoid unused
       contract. All gates green (`make editor-check`,
       `make test-editor-browser`); the 109 existing editor tests pass
       unmodified.
2. Phase two: admonitions (cheapest, validates the mechanism on a real feature).
   - [x] GFM alert recognition on blockquotes, render + Tiptap decoration + slash
         entry; degradation test (renders as a blockquote without the extension).

     Landed as `admonition-extension.ts` (the data seams: parse, render,
     blockFromElement, blockToMarkdown -- registered as a feature extension
     through `register-extensions.ts`, with no edits to the core dispatchers),
     `tiptap-admonition-node.ts` (the editor-side callout node), and callout CSS
     in `markdown-editor.css` (theme-native per-kind accents, not GitHub's).
     Decisions/notes from the phase:
     - The mechanism proved out: the whole feature is a new module plus one
       `registerExtension` call. Feature extensions are consulted before the
       base fallback (the registry's `fallback` flag), so the admonition
       handler claims an alert blockquote before base treats it as a plain one.
     - Marker recognition is on the *mdast* blockquote (first paragraph text
       opens with `[!KIND]` on its own line). In the visual editor, marked +
       the soft-break collapse merge the marker into the body, so
       `upgradeAlertBlockquotes` runs on the ProseMirror doc *before*
       `collapseSoftBreaks` to promote alert blockquotes to admonition nodes
       while the marker is still line-isolated.
     - One callout DOM contract across render and the Tiptap node:
       `div.markdown-alert > p.markdown-alert-title + div.markdown-alert-body`.
       `blockFromElement` reads `.markdown-alert-body` (the title is chrome),
       closing the editor round-trip (verified exact in the browser).
     - Degradation: alerts are valid GFM and round-trip byte-for-byte, so a
       no-extension/no-JS reader sees readable `> [!NOTE]` source (pinned by the
       round-trip tests rather than a registry-disabled test, since the registry
       is process-global).
     - `renderMarkdown` is currently a mode-switch validation step, not a live
       preview pane (ADR-040), so the callout chrome is visible via the Tiptap
       node in the visual surface, not a preview.
     - Deferred: switching an existing admonition's kind in the editor (insert
       is note-only; other kinds round-trip from source). 125 editor tests
       green; `make check` and `make test-editor-browser` pass.
3. Phase three: tables.
   - [ ] Model + render + `@tiptap/extension-table` editing + pipe-table
         serialiser + slash insert; round-trip and cell-edit smoke tests. Adopt
         Lit for the table view controls (per the Lit spike).
4. Phase four: collapsibles.
   - [ ] Custom mkdocs `???`/`???+` micromark/remark parser (the main risk, with
         focused parsing tests), model + render (shared callout chrome with
         admonitions) + custom Tiptap collapsible node + toggle UI + slash entry;
         round-trip (`???` vs `???+`) and degradation tests.
5. Phase five: footnotes (the most complex; inline plus document-level).
   - [ ] `footnoteReference` / `footnoteDefinition` model (inline + block), render
         (superscript references linking to a collected definitions list with
         back-links), Tiptap inline reference node and definition handling, and a
         serialiser preserving `[^id]` labels; round-trip and degradation tests.
6. Phase six: server guard and docs.
   - [ ] Narrow the Haskell guard to raw-HTML rejection (drop block-structure
         validation); `MicroHttp.TestApp` tests for the narrowed guard. ADR for
         the extension architecture and the guard change; record the Lit
         view-layer adoption; mark this RFC Completed.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

Resolved with the owner (2026-06-16):

- **Collapsible syntax:** mkdocs-material `???` / `???+` only (custom parser), with
  no GitHub `<details>` path ever; separate from the GFM-alert admonitions, the
  two sharing rendered callout chrome.
- **Server guard scope:** narrow to raw-HTML rejection only; drop block-structure
  validation. Accepted as the conclusion of ADR-040.
- **Lit adoption:** adopt for the view layer, landing with the table phase.
- **Inline extensions:** in scope. Footnotes require an inline reference node and a
  document-level definition set, so the registry and model cover inline (not only
  block) extensions from the start.
- **CodeMirror source highlighting:** deferred. New syntaxes rely on
  `lang-markdown`'s defaults for now; bespoke highlighting is later polish.

Still open:

- **mkdocs parser scope:** how much of the mkdocs/Python-Markdown admonition
  grammar to implement -- just `???`/`???+` with a type and optional title, or also
  nested admonitions and the full type set? Recommendation: the minimal
  `???`/`???+ type "title"` with a fixed type set first; nesting later if needed.
- **Footnote editing in Tiptap:** a community footnote extension versus a custom
  inline node plus managed definition region; decide during the footnotes phase
  against round-trip fidelity and Web Awesome/Lit fit.
