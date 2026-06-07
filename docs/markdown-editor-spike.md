# Markdown Editor Spike Design

## Markdown Editor Spike Goal

Build a small TestApp spike that proves MicroHttp can serve an htmx-driven,
web-component-based editor while keeping Markdown as the saved document format.

The spike should validate the browser and server interaction model before the
editor becomes a separate application or library. It should not attempt to build
a complete Markdown editor.

## Markdown Editor Spike Non-Goals

- No general-purpose HTML page editor.
- No arbitrary HTML persistence.
- No JavaScript framework dependency.
- No database-backed persistence.
- No collaborative editing.
- No complete CommonMark implementation in the first spike.
- No reusable production editor package in the first spike.

## Markdown Editor Source Of Truth

Markdown is the canonical saved representation.

The editable HTML view is a projection of Markdown, not the durable document
model. Browser DOM content must be normalised back to Markdown before it is
submitted to the server.

This direction avoids a common failure mode where a visual editor starts as
arbitrary `contenteditable` HTML and later cannot be converted to clean Markdown
without data loss or surprising output.

## Markdown Editor Supported Content Subset

The long-term Markdown family should be GitHub-Flavored Markdown plus selected
MkDocs and Zensical extensions. The first visual editor should expose only a
small subset of that family with direct Markdown representations.

Initial supported block content:

- Paragraphs.
- Headings from `h1` to `h3`.
- Unordered lists.
- Ordered lists.
- Blockquotes.
- Code blocks.
- Horizontal rules.

Initial supported inline content:

- Plain text.
- Strong emphasis.
- Emphasis.
- Inline code.
- Links.

Initial unsupported content:

- Arbitrary `div` and `span` wrappers.
- Inline styles.
- Raw HTML blocks.
- Script tags.
- Event-handler attributes.
- Tables.
- Images, including SVG images.
- Arbitrary attachments.
- Embedded htmx attributes inside saved document content.
- Custom elements inside saved document content.

Tables, images, and attachments are expected later capabilities, but each needs
a clear Markdown representation, asset-storage contract, and round-trip rule
before it becomes editable content.

## Markdown Editor Future Content Scope

Later versions should support tables, images, SVG images, and arbitrary
attachments after the core Markdown editing loop is proven.

Tables should use a GitHub-Flavored Markdown table representation unless a later
parser spike shows that a different table contract is more practical under
MicroHs.

Images should use ordinary Markdown image syntax for bitmap images:

```markdown
![Alt text](attachments/example.png)
```

SVG should initially be treated as an image asset referenced from Markdown, not
as inline arbitrary HTML inside the document body.

```markdown
![Architecture sketch](attachments/sketch.svg)
```

Arbitrary attachments should use normal links from Markdown:

```markdown
[Download source file](attachments/source.zip)
```

Attachment uploads should be modelled as document-adjacent assets rather than
embedded document content. A future store layout could keep a document and its
assets together.

```text
data/documents/home/content.md
data/documents/home/attachments/sketch.svg
data/documents/home/attachments/source.zip
```

The editor shell may use web components for upload controls, asset pickers, and
attachment previews. Those web components remain editor UI and should not become
custom elements inside the saved Markdown document.

## Markdown Editor Browser Architecture

The browser should use a custom element as the editor boundary.

```html
<markdown-editor name="markdown" mode="visual" src="/documents/home"></markdown-editor>
```

The custom element owns:

- The editable visual surface.
- The raw Markdown textarea when source mode is enabled.
- Conversion from the current visual state to Markdown before form submission.
- Conversion from Markdown to an HTML projection for preview or visual editing.
- Editor mode switching between visual, source, and split views.

The custom element must expose its value through normal form submission
mechanics. htmx should not need to know about the editor internals.

## Markdown Editor htmx Boundary

htmx should handle transport and server fragment replacement. It should not own
editor state.

The edit form should submit Markdown through a hidden input or form-associated
custom-element equivalent.

```html
<form
  hx-post="/documents/home"
  hx-trigger="submit, editor:changed delay:2s from:markdown-editor"
  hx-target="#save-status"
  hx-swap="innerHTML"
>
  <markdown-editor name="markdown" mode="visual" src="/documents/home"></markdown-editor>
  <input type="hidden" name="markdown" id="markdown-field">
  <button type="submit">Save</button>
</form>

<div id="save-status"></div>
```

Before htmx submits the request, the editor should serialise the current
document to Markdown and write it to the submitted field.

```javascript
form.addEventListener("htmx:configRequest", function () {
  hiddenMarkdownField.value = editor.toMarkdown();
});
```

The same contract supports autosave by dispatching a custom event from the
editor and using `hx-trigger` on the form.

```html
<form
  hx-post="/documents/home"
  hx-trigger="submit, editor:changed delay:2s from:markdown-editor"
  hx-target="#save-status"
  hx-swap="innerHTML"
>
</form>
```

## Markdown Editor Server Routes

The TestApp spike should keep routes small and explicit.

```text
GET  /documents/:id/edit
POST /documents/:id
GET  /documents/:id
GET  /static/:path
```

`GET /documents/:id/edit` returns the editor shell with a document `src`. It
does not embed the Markdown document in the page response.

`POST /documents/:id` reads the submitted `markdown` field, validates the
supported subset, writes the Markdown document, and returns a save-status
fragment.

`GET /documents/:id` returns the saved Markdown document as `text/markdown`.
The editor is responsible for parsing and rendering that Markdown for preview or
visual editing.

`GET /static/:path` serves TestApp static assets such as editor JavaScript, CSS,
images, fonts, and web-component source files.

## Markdown Editor Server Responsibilities

The server owns:

- Route dispatch.
- Request body parsing.
- Markdown persistence.
- Minimal validation needed to reject clearly unsupported spike submissions.
- Rendering htmx fragments for save status and validation failures.

The server must not trust submitted HTML as document content. The durable
contract is Markdown text. Markdown parsing, rendering, preview, and visual
editing are editor responsibilities under ADR-019.

## Markdown Editor TestApp Scope

The first implementation can live inside `src/TestApp.hs` and supporting static
assets served by the TestApp.

This keeps the spike close to the running server and avoids introducing a new
application structure before the interaction model is proven. The code should
stay easy to delete or extract once the editor grows beyond a spike.

The TestApp spike may use a simple file under a local data directory:

```text
data/documents/home.md
```

The first persistence implementation can be direct and synchronous. A later
production implementation should move document writes behind the planned
filesystem store.

## Markdown Editor Static Asset Scope

The TestApp should use a dedicated static folder for generated and hand-written
editor assets that are served directly.

```text
static/
  editor/
    markdown-editor.js
    markdown-editor.css
```

The TypeScript source for the editor web component lives under `src/` with the
TestApp source, not under `static/`:

```text
src/
  TestApp/
    Editor/
      index.ts
      markdown-editor-element.ts
      markdown-render.ts
      markdown-serialise.ts
```

The TestApp should serve these files through an explicit static route, such as
`GET /static/:path`. The route should normalise requested paths and reject path
traversal before reading from disk.

The first TypeScript build emits one browser JavaScript bundle. Later versions
may add images, fonts, and generated web-component bundles under the same static
root.

## Markdown Editor Rendering Pipeline

The intended long-term pipeline is:

```text
Markdown source
  -> Markdown parse result
  -> Markdown-shaped editor model
  -> visual HTML projection
  -> edit operation
  -> normalised Markdown
  -> saved Markdown
```

The first spike originally simplified this pipeline:

```text
Markdown source
  -> browser projection
  -> visual edits
  -> browser serialises supported DOM to Markdown
  -> server saves Markdown
```

That simplification is acceptable only while the supported content subset stays
small and explicit.

Phase Four now introduces a small typed editor model in TypeScript. The browser
pipeline for preview and visual rendering is:

```text
Markdown source
  -> typed editor document
  -> visual HTML projection
```

Visual-mode serialisation also uses the typed editor model:

```text
visual DOM projection
  -> typed editor document
  -> Markdown source
```

Phase Three showed that duplicating Markdown parsing and rendering in browser
JavaScript and TestApp Haskell becomes awkward as soon as inline content and
lists are added. The next design spike should evaluate a single Markdown AST
contract before adding more editing behaviours.

The first AST spike uses remark and mdast as a reference implementation:

```sh
make spike-remark-ast
```

This target installs JavaScript dependencies under `build/` only, parses the
current supported subset with `remark-parse` and `remark-gfm`, validates the
current subset against mdast node types, renders HTML through the
remark-to-rehype pipeline, and writes a report to
`build/remark-spike/report.json`.

## Markdown Editor Visual Editing Strategy

The first visual editor can use a `contenteditable` region with a constrained
toolbar. The toolbar should create only supported Markdown-compatible structures.

The editor should avoid exposing native browser commands that generate
uncontrolled markup. If browser commands are used for the spike, the component
must normalise the resulting DOM before serialising Markdown.

The visual surface should not include htmx attributes or custom elements inside
the editable document. htmx and web components are part of the editor shell, not
part of the saved document content.

## Markdown Editor Mode Strategy

The editor should eventually support three modes.

`visual` mode shows the editable rendered projection.

`source` mode shows the raw Markdown textarea.

`split` mode shows source and rendered projection side by side.

The first spike should start with `visual` mode and submit Markdown. The next
increment should add `source` mode. Split mode should follow only after visual
and source modes share a single Markdown value contract.

## Markdown Editor Validation Strategy

Validation should reject content that cannot round-trip through the supported
Markdown subset.

The first validation pass can be conservative:

- Reject raw HTML in submitted Markdown.
- Reject unsupported block structures.
- Reject unsupported inline structures.
- Return an htmx validation fragment instead of saving invalid content.

The spike may initially validate only the obvious raw HTML and unsupported
feature cases. The design should not imply that unsupported content is accepted.

## Markdown Editor Security Boundary

The saved Markdown should be rendered through a controlled renderer. Raw HTML in
Markdown should be disabled or rejected unless a later decision explicitly
allows trusted author HTML.

Generated preview HTML should be treated the same way as public rendered HTML.
Preview must not allow a broader content policy than saved page rendering.

## Markdown Editor First Spike Plan

### Markdown Editor Spike Phase One: Implemented

- Rendered `GET /documents/home/edit` from TestApp.
- Included htmx and the `markdown-editor` custom element script.
- Added `static/editor/markdown-editor.js` and
  `static/editor/markdown-editor.css`.
- Served editor assets through explicit `GET /static/editor/:file` routes.
- Seeded the editor with a small Markdown document.
- Supported a constrained visual editor for paragraphs and headings.
- Submitted Markdown through htmx to `POST /documents/home`.
- Returned a save-status fragment.
- Added a browser smoke script that starts TestApp, exercises the editor save
  flow, and closes the browser and server afterwards.

### Markdown Editor Spike Phase Two: Implemented

- Added raw Markdown source mode with `GET /documents/home/edit?mode=source`.
- Kept source and visual modes behind one submitted `markdown` field.
- Preserved exact source textarea content when source mode submits.
- Added conservative server-side validation for the current supported subset:
  headings from `h1` to `h3` and paragraphs.
- Rejected obvious raw HTML and unsupported Markdown syntax with an htmx status
  fragment instead of saving.
- Kept persistence deferred; the phase still returns save or validation status
  fragments from the TestApp spike.

### Markdown Editor Spike Phase Three: Implemented

- Added strong emphasis, emphasis, inline code, and links.
- Added unordered and ordered lists.
- Persisted submitted Markdown to `data/documents/home.md` through a small
  TestApp document-store seam.
- Rendered `GET /documents/home` from the saved Markdown.
- Added `POST /documents/home/preview` as a temporary server-side preview path.
- Returned preview HTML as an htmx fragment.
- Kept the parser and renderer deliberately small and local to the TestApp
  spike; it is not a complete Markdown implementation.

### Markdown Editor Spike Phase Four: Implemented

- Moved preview rendering into the `<markdown-editor>` web component.
- Kept htmx submissions as Markdown text only.
- Added split mode with source and preview panes sharing one Markdown value.
- Added autosave using an editor-dispatched `editor:changed` event and htmx
  delayed trigger.
- Moved editor source to TypeScript under `src/TestApp/Editor/`, with Bun
  building the served JavaScript bundle.
- Added a typed editor document model between Markdown parsing and HTML
  rendering.
- Changed visual DOM serialisation to produce the typed editor document before
  producing Markdown.
- Added horizontal-rule support through Markdown parsing, the typed editor
  document, HTML rendering, and DOM serialisation.
- Changed `GET /documents/:id/edit` to return an editor shell that fetches the
  Markdown document through `<markdown-editor src="/documents/:id">`.
- Changed `GET /documents/:id` to return raw `text/markdown`.
- Removed the server-side preview route from the active TestApp route set.
- Removed server-side Markdown rendering from the active TestApp
  responsibilities.
- Added a remark/mdast adapter that converts the current supported subset into
  the typed editor document model.
- Kept the local parser as the active editor parser while the remark adapter is
  proven with parity tests.
- Switched the public editor parser to the remark/mdast adapter.
- Kept the hand-written parser as a local legacy parser for parity tests while
  the adapter settles.
- Observed that bundling remark into the browser editor grows the editor bundle
  to roughly 0.33 MB in the current Bun build.
- Added editor-side parse error feedback for unsupported Markdown and suppress
  autosave events while the source cannot be parsed.
- Use remark and mdast as reference fixtures for editor-owned parsing and
  rendering behaviour.

Phase Four is complete because the browser now owns Markdown parsing, rendering,
preview, and visual-editing projection. The TestApp server stores and serves
Markdown text and static editor assets, but no longer owns Markdown rendering.

### Markdown Editor Spike Phase Five: In Progress

Scope: expand the basic non-asset Markdown subset after the browser-owned
pipeline is in place. Each supported feature must pass through the typed editor
model, remark parser, HTML rendering, DOM serialisation, TestApp save validation,
and browser smoke flow.

- Added fenced code block support through the typed editor model, remark parser,
  HTML rendering, DOM serialisation, and browser smoke flow.
- Updated the TestApp save validator to accept fenced code blocks in the current
  editor subset.
- Added blockquote support through the typed editor model, remark parser, HTML
  rendering, DOM serialisation, TestApp save validation, and browser smoke flow.
- Added hard line break support through the typed editor model, remark parser,
  HTML rendering, DOM serialisation, and browser smoke flow. The editor
  serialises generated hard breaks with backslash-newline rather than trailing
  spaces.
- Tables are explicitly deferred unless a later decision moves them into this
  phase.
- Phase Five should stop after hard breaks if the current basic non-asset subset
  is enough for the next design discussion. Before Phase Six, revisit visual
  controls and whether Tiptap should own the editing surface.

### Markdown Editor Spike Phase Six: In Progress

Scope: introduce the next editor architecture before table work. The first slice
uses Tiptap/ProseMirror for visual editing behind the existing
`<markdown-editor>` boundary. Later slices add toolbar controls, raw Markdown
editing with CodeMirror, and Web Awesome controls.

- Replaced the hand-built `contenteditable` visual surface with a Tiptap adapter.
- Preserve the existing htmx form contract, autosave event, source mode, and
  split mode.
- Keep remark/mdast as a reference parser and validation fixture while Tiptap's
  Markdown extension remains beta.
- Observed that adding Tiptap grows the current minified Bun editor bundle to
  roughly 0.62 MB.
- Add a top toolbar in a later slice with mode switching, style controls,
  structure controls, and theme switching.
- Add CodeMirror for raw Markdown editing and syntax highlighting in a later
  slice.
- Use Web Awesome for future web-component controls and styling.
- Consider Lit for the editor shell once manual DOM state management becomes the
  main source of complexity.

### Markdown Editor Spike Phase Seven: Planned

Scope: add GitHub-Flavored Markdown tables after table normalisation rules are
decided and the Tiptap editing surface is stable.

- Parse table mdast nodes into the typed editor model or Tiptap table schema.
- Render table previews and visual editable projections.
- Serialise supported table DOM or Tiptap state back to normalised Markdown.
- Extend TestApp save validation and browser smoke coverage.

### Markdown Editor Spike Phase Eight: Planned

Scope: add image and attachment support once storage and path rules are decided.

- Add image insertion for Markdown image syntax.
- Treat SVG as a linked image asset by default, not inline raw HTML.
- Add arbitrary attachment insertion as Markdown links.
- Add asset storage, path normalisation, de-duplication, and deletion rules.

### Markdown Editor Spike Phase Nine: Planned

Scope: decide whether the editor remains a TestApp spike or moves into a
separate package/application boundary.

- Continue extracting stable editor code into typed editor modules.
- Decide whether the editor parser and renderer belong in MicroHttp examples, a
  separate package, or a later application repository.

## Markdown Editor Decision Status

The first stable content contract should be a basic subset of
GitHub-Flavored Markdown. The long-term direction is GitHub-Flavored Markdown
plus selected MkDocs and Zensical extensions.

ADR-019 decides that the MicroHttp server should stay minimal for Markdown
documents. The server stores submitted Markdown and serves Markdown documents or
static editor assets. The editor owns Markdown parsing, rendering, preview, and
visual editing.

remark and mdast are development/reference tools for fixtures and expected
Markdown behaviour, not production server runtime dependencies. The editor's
public parser now uses remark/mdast behind the existing parser contract. The
hand-written parser remains only as a parity fixture while the adapter settles.

The external Markdown parser spike has selected remark and mdast for the active
browser-owned parser path. The current local parser should stay as a temporary
parity fixture and should not regain active editor-parser ownership without a
renewed decision.

Table syntax and normalisation rules are deferred.

Allowed image and attachment file types are deferred.

Inline SVG embedding versus linked SVG image assets is deferred. Until that
decision is made, SVG should be treated as a linked image asset.

Attachment path generation, normalisation, and de-duplication are deferred.

The sanitisation policy for trusted local authoring versus multi-user authoring
is deferred.

TestApp static editor assets should live under a dedicated `static/` folder and
be served by an explicit static route.
