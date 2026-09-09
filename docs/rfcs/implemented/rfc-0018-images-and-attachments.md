---
id: RFC-0018
name: Images and Attachments
status: Implemented
owners:
    - alistair
created: 2026-06-17
updated: 2026-06-17
supersedes: []
superseded_by: null
---

# Images and Attachments

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-17 11:29 |
| Started   | 2026-06-17 11:29 |
| Completed | 2026-06-17 12:25 |

## Summary

Let users add images and file attachments to a document: upload the bytes to the
server, store them once in a content-addressed blob store, serve them safely with
a zero-copy `sendfile` response, and reference them from Markdown -- images as
`![alt](url)` rendered inline, other files as `[name](url)` download links. The
upload is a small raw-body `POST` from the JS editor (drag, paste, or a file
picker); the server adds an attachment store and a serving route alongside the
existing document store, and the editor adds an image content extension on the
RFC-0017 registry plus the upload-and-insert UX. Raw HTML stays rejected, so no
`<img>`/`<a>` tags are introduced; the new bytes are untrusted and served from a
sandboxed path with `nosniff`, a restrictive CSP, and download disposition for
non-inline types.

## Context

The editor has no images today: the Markdown subset rejects `image` mdast nodes
(the strict parse seam throws `Unsupported Markdown node ... image`), and there is
no way to get a binary file from the user to the server -- the only `POST` body
the app parses is `application/x-www-form-urlencoded` (`markdown=...`), read
strictly with a 1 MiB bound (`readBodyStrict`). Documents are filesystem-backed
(`DocumentStore`, ADR-0014); static files are already served safely and zero-copy
(`Static.static`, path-traversal-safe, `FileBody` + `sendfile`, `contentTypeFor`
extension mapping -- ADR-0018/0030/0034). So the serving half of "attachments"
largely exists as a pattern to reuse; the missing pieces are *receiving* bytes,
*storing* them, *rendering* images, and the *editor UX* to add them.

Three project constraints shape the design:

- **Raw HTML is uniformly rejected** (ADR-0040/0041, the server's only save-time
  guard). Images must therefore use Markdown `![]()`, not `<img>`, and the served
  bytes are untrusted content that must not become an injection vector.
- **Rendering is browser-owned and the no-JavaScript path is raw Markdown**
  (ADR-0040, progressive enhancement ADR-0039). Upload is inherently a scripted
  interaction; the no-JS experience degrades to referencing already-uploaded URLs
  by typing Markdown, not uploading.
- **The content-extension registry (RFC-0017)** is the contract for new
  Markdown types: images are a new inline extension (parse/render/serialise +
  a Tiptap node), one module plus one `registerExtension` call.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- A server attachment store: upload bytes once, address them by content hash,
  store on the filesystem (ADR-0014 lineage), and serve them safely and zero-copy.
- Images rendered inline from `![alt](url)` (a new content extension + Tiptap
  node); other files referenced as `[name](url)` download links.
- Editor UX to add images and attachments: a file picker, drag-and-drop, and
  paste, each uploading then inserting the right Markdown at the cursor.
- Safe serving of untrusted bytes: correct `Content-Type`, `nosniff`, a
  restrictive CSP, download disposition for non-inline types, a type allow-list,
  and a bounded upload size -- with raw HTML still rejected.
- Round-trip fidelity: an image or attachment reference round-trips through the
  editor like any other Markdown (per-extension golden tests).

## Non-Goals

- No image editing (crop/resize/rotate) or server-side transcoding/thumbnails.
- No rich media (video/audio players); a video file is just an attachment link.
- No no-JavaScript *upload* in the first cut (multipart form upload is a deferred
  enhancement, see Open Questions); no-JS users reference existing URLs by typing.
- No external image proxying or hot-link rewriting; `![](https://...)` external
  URLs are rendered as-is (subject to the allow-list decision below).
- No attachment garbage collection in the first cut (orphaned blobs are
  tolerated; a mark-sweep is a later concern, see Open Questions).
- No authentication/authorization model change; this rides whatever the fronting
  proxy provides (ADR-0031). Quotas/rate-limiting are out of scope for v1.

## Proposal

### Upload transport: a raw-body POST from the editor

`POST /attachments` with the file bytes as the **raw request body** (not
multipart), the original filename in a header (`X-Attachment-Filename`,
percent-encoded) and the browser-declared type in `Content-Type`. The editor
sends it with `fetch(file)` (the `File`/`Blob` is the body). The handler reads
the body with the existing `readBodyStrict` bounded reader, hashes it, stores it,
and returns a small JSON body `{"url": "/attachments/<hash>/<filename>"}`.

Rationale: multipart/form-data is the standard HTML file-upload encoding and the
only one that works without JavaScript, but parsing it (streaming boundary
parser) is a non-trivial new component, and upload is a scripted interaction
anyway. A raw-body POST reuses the existing bounded body reader unchanged and
keeps the server simple. Multipart (for a no-JS `<input type=file>`) is a
deferred enhancement (Open Questions), not a v1 requirement.

The server's global body cap is `settingsMaxBodyBytes`; uploads are larger than
the 1 MiB form bound, so an attachment size limit (config key, default e.g.
10 MiB) is introduced and the server cap must be at least that. The upload
handler enforces the attachment limit explicitly via `readBodyStrict`, returning
`413` when exceeded.

### Storage: a content-addressed blob store

A new `AttachmentStore` mirrors `DocumentStore` (filesystem-backed, ADR-0014).
Bytes are addressed by their SHA-256 hex hash and written once to
`data/attachments/<hash>` (configurable root, like `document_root`). Writing is
idempotent: an identical upload dedups to the same blob. The original filename is
*not* part of the stored path -- it travels in the URL
(`/attachments/<hash>/<filename>`) where it serves two purposes: the file
extension drives `contentTypeFor`, and the name is the download filename. The
hash is the integrity/identity; the trailing name is cosmetic and may be anything
safe.

Decision: filename-in-URL rather than a sidecar metadata file, to keep the store
a pure content-addressed blob directory with no parallel index to keep in sync.
(A future need for richer metadata -- declared MIME, upload time -- would add a
`<hash>.meta` sidecar; deferred.)

### Serving: a safe, zero-copy attachment route

`GET /attachments/:hash/:name` resolves `data/attachments/<hash>` and serves it as
a `FileBody` (size resolved once, exact `Content-Length`, zero-copy `sendfile` --
ADR-0034), reusing the path-safety discipline of `Static` (the hash is validated
as lowercase hex; `name` is cosmetic and never touches the filesystem path, so no
traversal is possible). Response headers:

- `Content-Type` from the URL filename extension via `contentTypeFor`.
- `X-Content-Type-Options: nosniff` (never let the browser re-interpret type).
- `Content-Security-Policy: default-src 'none'; sandbox` on every attachment
  response (a stored HTML/SVG blob cannot execute or fetch).
- `Content-Disposition: inline` for the inline-renderable image types
  (png/jpeg/gif/webp), `attachment; filename="<name>"` for everything else.
- Long-lived immutable caching (`Cache-Control: public, max-age=31536000,
  immutable`) -- safe because the URL is content-addressed.

Content-addressing plus a hex-only hash segment means there is no overwrite,
collision, or path-escape surface; a blob is whatever bytes hashed to that name.

### Rendering: an image content extension; attachments are links

- **Images.** A new `image-extension.ts` on the RFC-0017 registry: parse the
  mdast `image` node to a custom inline (or a dedicated model node) carrying
  `src`/`alt`/`title`; render `<img src alt title>` (escaped); serialise back to
  `![alt](src "title")`; a Tiptap `Image` node for the visual editor (atom
  inline). The `src` is emitted/escaped as text -- this is Markdown image syntax,
  not raw HTML, so it introduces no new HTML-injection surface (the renderer
  escapes attributes exactly as it does for links today).
- **Attachments.** A non-image file is referenced as an ordinary Markdown link
  `[filename](/attachments/<hash>/<name>)` -- already fully supported (inline
  links, and now reference links). No new extension; the editor just inserts a
  link whose target is the upload URL and whose text is the filename.

### Editor UX: pick, drag, paste -> upload -> insert

The editor (JS) offers, for both images and arbitrary files:

- A toolbar/slash entry ("Image", "File") opening a native file picker.
- Drag-and-drop onto the editor surface.
- Paste (clipboard image -> upload as PNG).

Each path: read the `File`, `POST /attachments`, await the `{url}`, then insert
`![name](url)` for an image (alt defaults to the filename, editable) or
`[name](url)` for any other file, at the caret. A transient "uploading…"
placeholder is shown and replaced on success; an upload error surfaces a
dismissable message and inserts nothing. This rides the existing controller/Lit
view-layer seams (RFC-0017); no server round-trip changes to the document save
path (the Markdown already carries the URL).

### Security model

- Raw HTML stays uniformly rejected (ADR-0040/0041): images use `![]()`, so no
  `<img>`/`<a>`/`<svg>` tags enter the document; the save-time guard is unchanged.
- Uploaded bytes are untrusted and served sandboxed: `nosniff`, the `default-src
  'none'; sandbox` CSP, correct `Content-Type`, and download disposition for
  non-inline types together neutralise the classic "upload an HTML/SVG file and
  serve it inline as same-origin script" attack.
- **SVG** is the sharpest case (it can carry script). Decided: SVG is allowed to
  upload but served as a **download** (`Content-Disposition: attachment`), never
  rendered inline as an image, and covered by the CSP above; it is *not* in the
  inline-image type set.
- A **type allow-list** (by extension/declared type) gates uploads: inline image
  types (png/jpeg/gif/webp) plus a configurable set of document types
  (pdf/txt/csv/zip/…); anything else is rejected at upload (`415`). Executable
  and HTML types are never accepted.
- A **size limit** (config, default ~10 MiB) bounds each upload; the body reader
  returns `413` past it; the server `settingsMaxBodyBytes` is raised to match.

## Alternatives Considered

- **Multipart/form-data upload.** Standard and no-JS-capable, but requires a
  streaming multipart boundary parser (a meaningful new component) for a scripted
  interaction. Deferred to a no-JS enhancement; raw-body POST chosen for v1.
- **Inline data-URI images (`![](data:image/png;base64,...)`).** No server
  upload/storage at all, but it bloats the Markdown (and the document store) with
  base64, breaks dedup, and makes large images pathological. Rejected; uploaded
  blobs referenced by URL chosen instead.
- **Per-document attachment folders (`data/documents/<id>.attachments/<name>`).**
  Simple ownership, but no dedup, filename-collision handling, and rename/delete
  coupling to documents. Content-addressed blobs chosen for dedup, immutability,
  and trivial cacheable serving; document<->blob ownership (for GC) is deferred.
- **Allowing raw `<img>`/`<details>`-style HTML for media.** Reopens the raw-HTML
  trust hole ADR-0040/0041 closed. Rejected; Markdown `![]()` only.
- **Storing declared MIME in a sidecar.** Avoided for v1 by deriving type from the
  URL filename extension (reusing `contentTypeFor`); a sidecar is a later add if
  richer metadata is needed.

## Security Impact

- New trust boundary: the server now accepts and serves *arbitrary user bytes*.
  Mitigated by the type allow-list, size bound, content-addressing (no
  overwrite/traversal), `nosniff`, the sandbox CSP, and download disposition for
  non-inline types. The save-time raw-HTML rejection is unchanged.
- The hash path segment is validated as hex; the cosmetic filename never reaches
  the filesystem, so the `Static` path-safety guarantees are preserved.
- New denial-of-service surface (disk fill via many uploads): bounded per-upload;
  global quota/rate-limiting is out of scope for v1 and called out as a follow-up
  (a fronting proxy, ADR-0031, can also rate-limit `POST /attachments`).

## Reliability Impact

- Idempotent, content-addressed writes: a re-upload or retry converges to the
  same blob; a partial write is to a temp file renamed on completion (no
  half-written blob is ever addressable).
- Orphaned blobs (a document edited to drop an image) are tolerated; they waste
  disk but never break serving. A mark-sweep GC (scan all documents' Markdown for
  referenced hashes) is a deferred follow-up.
- Serving reuses the proven zero-copy `sendfile` path (ADR-0034); a missing blob is
  a `404` decided before the head is written, as in `Static`.

## Compatibility Impact

- Additive: new routes (`POST /attachments`, `GET /attachments/:hash/:name`), a
  new store and config keys (`attachment_root`, `attachment_max_bytes`,
  allow-list), and a new editor extension. No change to the document save/serve
  contract or existing routes.
- The Markdown subset grows by the `image` node; documents using `![]()` are
  portable GFM. `settingsMaxBodyBytes` default rises to accommodate uploads.
- New editor dependency surface: a Tiptap image node (Tiptap ships `@tiptap/
  extension-image`; evaluate vs a small custom node, consistent with how
  collapsibles avoided a Pro dependency).

## Testing and Quality Gates

- `make check` green after each phase; `make test-editor-browser` after the
  editor phases.
- Server (`MicroHttp.TestApp` tests): upload stores and dedups; the returned URL
  serves the bytes with the right `Content-Type`/disposition/`nosniff`/CSP; a
  hex-invalid or traversal hash is `404`; an over-size upload is `413`; a
  disallowed type is `415`; a missing blob is `404`.
- Editor (per-extension golden tests): image parse/render/serialise/round-trip;
  a browser smoke test for pick/drag/paste -> upload -> insert and for an
  attachment link; a degradation note for the no-JS path.

## Rollout Plan

1. Phase one: server attachment store, upload, and safe serving.
   - [x] `AttachmentStore` (content-addressed filesystem blobs, idempotent temp-
         file-then-rename write); `POST /attachments` (bounded raw-body read,
         hash, store, JSON `{url}`, `413`/`415`); `GET /attachments/:hash/:name`
         (hex-validated, `FileBody`/`sendfile`, `contentTypeFor`, `nosniff`,
         sandbox CSP, inline/attachment disposition, immutable cache); config keys
         and the raised body cap; `MicroHttp.TestApp` tests.

     Landed as `MicroHttp.Attachment` (`contentHash`, `AttachmentStore`,
     `fileAttachmentStore`, `attachmentRoutes`) wired into the app's routes, with
     `MicroHttp.AttachmentSpec`. Notes / decisions forced by the MicroHs runtime:
     - **Content hash:** a 128-bit FNV-1a (two passes, 32 hex chars) -- MicroHs
       has no crypto library. It is *strict* (`BS.foldl'` directly over the
       `ByteString`): a first cut used lazy `foldl` over `unpack`, which
       stack-overflowed and crashed the server on a 2 MiB upload (caught by an
       end-to-end curl, not the small-input unit tests). Non-cryptographic;
       safety is the serving headers + allow-list, not the hash.
     - **Write is direct, not temp+rename:** MicroHs's `System.Directory` has no
       `renameFile`. Because the path is content-addressed, an identical
       re-upload overwrites with identical bytes -- idempotent dedup that also
       self-heals a partial write. (A future atomic-rename via FFI is possible.)
     - **Body cap:** the framing `settingsMaxBodyBytes` default was raised from
       1 MiB to 10 MiB (the upload limit). It is the global framing cap, so it
       must be at least the attachment limit; handlers keep their own tighter
       bounds (the document form still self-limits to 1 MiB).
     - **`pdf` content type:** `Static.contentTypeFor` has no `pdf` mapping, so a
       PDF serves as `application/octet-stream` + download disposition (correct,
       just generic); extending the type table is phase-four polish.
     - Verified end-to-end against the running server: small and 2 MiB uploads
       round-trip byte-identical; images serve inline, other types (incl. SVG) as
       downloads with `nosniff` + sandbox CSP + immutable cache; `415` for
       disallowed types; `404` for malformed or absent hashes. `make check` green
       (122 unit incl. 10 attachment, 38 integration).
2. Phase two: image content extension and Tiptap node.
   - [x] `image-extension.ts` (parse `image` mdast, render `<img>`, serialise
         `![alt](src "title")`) + a Tiptap image node; round-trip and degradation
         golden tests. Attachments need no extension (links already supported).

     Landed as `image-extension.ts` (registered after `reference-link` in
     `register-extensions.ts`) and `tiptap-image-node.ts` (wired into
     `tiptap-visual-editor.ts`), with `test/editor/image-extension.test.ts` (13
     golden tests: parse, render+escaping, round-trip, DOM serialise). Notes /
     decisions:
     - **Custom inline, no model change.** Images are a `type: "custom"`,
       `extension: "image"` inline carrying `{ alt, src, title }`, mirroring
       `reference-link` -- the `editor-model` `InlineNode` union is unchanged.
     - **`<img>` recognised without a marker class.** Unlike `reference-link`'s
       anchor (a plain `<a>` is already claimed by the base extension), a bare
       `<img>` is unambiguous, so `inlineFromElement` claims any `IMG` directly.
     - **Block-level `<img>` seam.** The visual editor renders a standalone
       `![](url)` as a *bare top-level* `<img>` (a direct child of the ProseMirror
       root, not wrapped in `<p>`). The base extension would treat that childless
       element as an empty paragraph and drop the image, so the extension adds a
       `blockFromElement` that wraps a block-level `<img>` in a paragraph. Covered
       by a dedicated test; the remark parse path already wraps standalone images.
     - **marked needs a parse handler.** `@tiptap/markdown` (marked) tokenises
       `![]()` correctly, but only maps a token to a node when the node declares
       `parseMarkdown` (+ `markdownTokenName`, defaulting to the node name). A
       node without it silently drops the image token (verified in-browser: the
       inline image degraded to its alt text and the standalone image vanished).
       The Tiptap `image` node therefore carries a `parseMarkdown(token)` mapping
       `{ href, text, title }` -> `{ src, alt, title }`. Serialising back to
       Markdown uses the DOM serialise seam (not marked), so no `renderMarkdown`
       is needed. No new dependency: a small custom node, not
       `@tiptap/extension-image` (consistent with collapsibles avoiding Pro).
     - Verified in the running editor: an inline titled image, a standalone
       external image, and an attachment link all load into the visual editor as
       `<img>`/`<a>` and round-trip byte-identically through `toMarkdown`.
       `make check` green (186 editor tests incl. 13 image, full server suite).
3. Phase three: editor upload UX.
   - [x] File picker + drag-and-drop + paste, each uploading via `POST
         /attachments` and inserting `![name](url)` (image) or `[name](url)`
         (attachment) at the caret, with an uploading placeholder and an error
         path; toolbar/slash entries. Browser-verified.

     Landed as `attachment-upload.ts` (the testable core: `uploadAttachment`
     -- raw-body POST + percent-encoded `X-Attachment-Filename`, 413/415 mapped
     to user messages; `isInlineImage` -- by extension, MIME fallback, SVG
     excluded; `attachmentMarkdown` -- `![]()` vs `[]()`) with
     `test/editor/attachment-upload.test.ts` (16 tests, `fetch` stubbed). Wired
     into `markdown-editor-element.ts`: a hidden multi-file `<input>`, `dragover`/
     `drop`/`paste` listeners on the editor body, an upload pipeline that shows an
     "Uploading…" status (the `markdown-editor__upload-notice` region) and an
     error notice on failure (inserting nothing), and `insertUpload` dispatching
     to the active editor. Insertion seams added: `insertImage`/`insertFileLink`
     on `TiptapVisualEditor` (Tiptap `insertContent`) and `insertMarkdown` on the
     CodeMirror source editor. Triggers: a command-bar "Insert image or file"
     button (always available) plus "Image"/"File" slash entries (Studio theme).
     Notes / decisions:
     - **Image vs link by the inline-image set, not `image/*`.** SVG is `image/*`
       but is served as a download, so it (and pdf/txt/...) inserts as a
       `[name](url)` link; only png/jpg/jpeg/gif/webp insert as `![]()` -- the
       classification mirrors the server's inline-disposition set exactly.
     - **Drag/paste claim files only.** The body listeners `preventDefault` (so
       ProseMirror/CodeMirror do not also handle the drop/paste) *only* when the
       transfer carries files; a normal text drag/paste is left untouched.
     - **Insert at the caret, not the drop point.** v1 inserts at the current
       selection via `insertContent`/`insertMarkdown`; precise drop-position
       insertion is a later refinement.
     - Browser-verified end-to-end against the running server: drag-drop of a PNG
       inserts an inline image and serves byte-identically with the hardening
       headers; a `.txt` inserts a download link; a `.exe` shows the 415 error and
       inserts nothing; paste of a PNG inserts inline; the same bytes dedup to one
       blob (distinct filenames in the URL). `make check` green (202 editor tests
       incl. 16 upload + full server suite).
4. Phase four: hardening and docs.
   - [x] Finalise the type allow-list and SVG handling; confirm the CSP/nosniff/
         disposition headers in the browser; size-limit and config docs; an ADR
         for the attachment store, the upload transport, and the serving security
         model; mark this RFC Completed.

     The type allow-list and SVG-as-download were settled in phase one; the
     CSP/nosniff/disposition/immutable-cache headers were confirmed in the browser
     during phases one and three (a PNG serves `inline`, a `.txt`/SVG as a
     download, all with `nosniff` + the sandbox CSP). The remaining code change
     was the content-type table: `Static.contentTypeFor` lacked the attachment
     types, so an allowed upload could serve with the wrong type -- notably
     `webp` (an inline image type) fell through to `application/octet-stream`.
     Added `webp`, `pdf`, `md`, `csv`, and `zip` mappings, with `StaticSpec`
     tests. The store, upload transport, and serving security model are recorded
     in ADR-0042. `make check` green.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

Resolved with the owner (2026-06-17):

- **No-JavaScript upload:** JS-only for v1. No multipart parser; no-JS users
  reference already-uploaded URLs by typing Markdown. Revisit multipart only if
  no-JS authoring becomes a requirement.
- **SVG:** allowed to upload but served as a download (`Content-Disposition:
  attachment`) only, never rendered inline as an image, and covered by the
  sandbox CSP. Not in the inline-image type set.
- **External image URLs:** `![](https://...)` external URLs are allowed and
  rendered as-is (the privacy/mixed-content trade-off is accepted; the fronting
  proxy and a future CSP can tighten this if needed).
- **Garbage collection:** orphaned blobs are tolerated in v1 (they waste disk but
  never break serving); a mark-sweep over documents' referenced hashes is a later
  follow-up.

Resolved during phase two (2026-06-17):

- **Tiptap image node:** a small custom node (`tiptap-image-node.ts`), not
  `@tiptap/extension-image` -- no new dependency, and the node only needs a
  `parseMarkdown` handler (marked tokenises `![]()` natively) plus the `<img>`
  render/parse markup the DOM serialise seam already round-trips. Consistent with
  collapsibles avoiding a Pro dependency.

Still open:

- **Quotas / rate-limiting:** per-document or global storage caps and upload rate
  limits -- in-app or delegated to the fronting proxy (ADR-0031)? Deferred.
