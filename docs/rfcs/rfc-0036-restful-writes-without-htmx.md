---
id: RFC-0036
name: RESTful Writes Without htmx
status: Draft
owners:
    - alistair
created: 2026-07-12
updated: 2026-07-12
supersedes: []
superseded_by: null
---

# RESTful Writes Without htmx

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-07-12 |
| Started   | 2026-07-12 |
| Completed |            |

## Summary

Retire the legacy flat-mode document store, replace the htmx autosave form
with editor-owned `fetch` requests, move the page body out of urlencoded form
fields into raw request bodies, and give the write endpoints proper HTTP
verbs: `PUT /drafts/*path` (autosave), `DELETE /drafts/*path` (discard),
`PUT /documents/*path` (publish), `DELETE /tree/*path` (delete to trash).
Domain operations without a clean verb mapping (create, move, rollback, undo,
restore) stay POST controllers. The plain form post remains as the
no-JavaScript floor. This removes the htmx dependency entirely (closing
RFC-0035's vendor-or-CDN open question), eliminates the urlencoded decode of
large page bodies -- the allocation storm behind the multi-second GC pauses
-- and supersedes the uncommitted C form-decode shim, which is dropped.

## Context

Three findings converged (2026-07-11 investigation):

- Every autosave and publish sends the whole page as one urlencoded form
  field (`markdown=...`, a `+` or `%XX` escape roughly every six bytes of
  prose). Decoding that field in interpreted MicroHs code costs tens of heap
  cells per byte, ~80-115MB of transient graph per save of a 73KB page,
  ballooning the heap to ~1GB and causing 10-25s stop-the-world GC pauses
  under search-indexing load.
- A measurement spike (`bench/FormDecodeBench.hs`, `make bench-form-decode`)
  showed no Haskell arrangement on mhs approaches native speed for
  dense-escape decoding: String pipeline 19ms, ByteString index loop 23ms,
  chunk-wise scanning 3.7-7.3s (mhs `unpack` is eager, so `elemIndex` loops
  are quadratic), memchr-assisted chunking 55ms, one C pass 0.05ms. An
  interim C decode shim (uncommitted) fixed the pauses but puts string
  manipulation in C, which we do not want to keep.
- The htmx autosave form is the last htmx consumer, and its hypermedia
  payload is already discarded: the form is `hx-swap="none"`, the editor
  drives save-status UI from request lifecycle events, and every other
  operation (create, move, delete, undo, trash, search) is already a plain
  `fetch` against JSON/status endpoints.

Sending the page body raw removes the decode entirely -- no urlencoding, no
per-byte work in any language -- and is faster than the C shim. Doing that
means replacing the htmx form with a fetch the editor owns, which in turn is
the natural moment to adopt honest HTTP verbs for the state-transfer
endpoints.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Flat mode (the pre-tree single-directory document store) is retired: one
  serving mode, one save path, one interaction model.
- Page bodies travel as raw request bytes; no urlencoded decode on the
  autosave or publish hot paths, in Haskell or C.
- htmx is removed: no CDN script, no `hx-*` attributes, no
  `isHtmxRequest`/fragment/`HX-Redirect` branches in handlers.
- State transfer uses resource verbs: `PUT`/`DELETE` on `/drafts/*path` and
  `PUT /documents/*path`, `DELETE /tree/*path`.
- Domain operations keep POST controllers: create, `?move`, `?rollback`,
  `/undo`, `/trash/*id`, `?asset`, `/index/refresh`.
- The no-JavaScript floor survives: plain form POST -> 303 -> GET, urlencoded,
  through the existing String pipeline.
- The interim C form-decode layer (cbits/microhttp_http.c and the
  `formFieldsBytes`/`normaliseFormNewlines`/`decodeFormBytes` API) is removed
  as superseded.

## Non-Goals

- The remaining ~85MB publish-path allocation (link-index page parse) -- a
  separate investigation.
- Multipart request parsing (the asset upload keeps its raw-body +
  `X-Attachment-Filename` contract).
- Authentication or CSRF protection (there is no authentication; the author
  identity header seam is unchanged, RFC-0032).
- WebDAV-style extension methods (`MOVE`): `parseMethod` deliberately accepts
  only the standard method set.

## Proposal

### Flat-mode retirement

The flat single-directory document store (the pre-RFC-0026 mode selected by
an empty `document_tree_root`) retires first, as a mechanical deletion: the
flat routes and handlers (`showDocument`, `editDocument`, `saveDocument`, the
index listing), the `DocumentStore` abstraction (tree mode never used it),
the flat `POST /attachments` store and its routes, the raw-HTML save guard
with its `validationStatusFragment` and the `maybeError` parameter threaded
through `editorPage`, the editor element's flat-vs-tree branches, and the
`document_root`/`attachment_root` config keys. `document_tree_root` becomes
required; startup fails with a clear message when it is missing. Shared
helpers the tree borrows from `Verso.Attachment` (percent-decoding, page
attachment types) move to their tree call sites or a smaller module. The
rest of this proposal then only has one mode to describe.

| Operation       | Today                            | After                              |
|-----------------|----------------------------------|------------------------------------|
| autosave        | htmx form POST `/documents/*p`   | `PUT /drafts/*p` (raw body)        |
| discard draft   | POST `?discard-draft`            | `DELETE /drafts/*p`                |
| publish         | POST `/documents/*p?publish`     | `PUT /documents/*p` (raw body)     |
| delete to trash | POST `/tree/*p?delete`           | `DELETE /tree/*p`                  |
| no-JS save      | form POST `/documents/*p`        | unchanged (forms only do GET/POST) |
| create          | POST `/tree/*parent`             | unchanged (POST to collection)     |
| move            | POST `/tree/*p?move`             | unchanged (two-phase controller)   |
| rollback        | POST `/documents/*p?rollback`    | unchanged (creates a revision)     |
| undo            | POST `/undo`                     | unchanged (appends to the op log)  |
| restore         | POST `/trash/*id`                | unchanged (trash-entry controller) |
| image titles    | fields on every save/publish     | POST `/documents/*p?image-titles`  |

Rationale for the split: `PUT` and `DELETE` fit operations that transfer or
remove resource state and are idempotent -- autosave is a retry-prone
debounced write (idempotent replace is exactly what it wants), and publish
already yields no new commit for unchanged bytes. Move, rollback, undo, and
restore are domain operations (impact plans, new revisions, log appends);
REST's answer for those is a POST controller, not a verb tunnel. Drafts get a
top-level `/drafts/` namespace (mirroring the `draft_root` storage split)
rather than a path suffix, because tree paths are user-controlled and suffix
segments could collide with real children. Delete lives on `/tree/*path`
because sections are deletable too and the tree namespace is where structural
management (create, move) already lives.

### Raw page bodies

`PUT /drafts/*path` and `PUT /documents/*path` take the markdown as the raw
request body (`Content-Type: text/markdown; charset=utf-8`), read via the
existing `readBodyStrict` under `formBodyLimit`, and store it verbatim --
byte-exactness per ADR-038, no newline normalisation (the editor emits LF).
CRLF normalisation remains a property of the urlencoded form path only, where
HTML form submission mandates CRLF.

The image-title sidecar sync (RFC-0019, ADR-049) leaves the save payload: the
editor calls the small `?image-titles` controller (urlencoded
`image_count`/`image_path_<i>`/`image_title_<i>` fields, handled by the
String pipeline) after a successful publish, and only when the page has
page-relative images. Autosaves stop carrying image fields entirely: drafts
have no sidecar metadata (RFC-0032 keeps the live page untouched until
publish), so today's per-autosave sync work is dead weight that this removes.

### Editor and interaction model

The editor owns all writes as `fetch` calls (it already does for create,
move, delete, undo, trash):

- The save controller debounces `editor:changed` (2s, matching today's
  `hx-trigger` delay) and issues `PUT /drafts/*path` in tree+versioning mode,
  falling back to the mode's existing save route otherwise, calling its own
  `markSaving`/`markSucceeded`/`markFailed` transitions around the request --
  replacing the `htmx:configRequest`/`beforeRequest`/`afterRequest`
  translation layer.
- Publish becomes `PUT /documents/*path` with the raw document, then the
  `?image-titles` controller call, then navigation -- same user-visible flow.
- Discard becomes `DELETE /drafts/*path`; the nav tree's delete becomes
  `DELETE /tree/*path`.
- The `<form>` around the editor stays for the no-JavaScript floor (native
  POST, `<noscript>` submit button, `ElementInternals.setFormValue`), but no
  JavaScript is wired to it.

The interaction model, recorded as an ADR: server-rendered HTML for documents
and navigation; fetch commands with status/JSON responses for mutations
(never HTML fragments); custom elements own client state; plain form post as
the no-JavaScript floor.

### Server-side cleanup

- `Router.put` helper (two lines; `Method` and `parseMethod` already cover
  PUT/DELETE).
- `treeSave` keeps only the form branch (urlencoded String pipeline -> draft
  or live write -> 303). The htmx fragment response and `saveStatusFragment`
  go; `clientRedirect`'s `HX-Redirect` branch goes (the editor navigates
  itself); all `isHtmxRequest` save/publish branches are removed.
- The htmx `<script>` tag leaves `editorPage` (RFC-0035's open question is
  closed by deletion).
- The old POST routes for publish, discard-draft, and tree delete are
  removed, not aliased: the editor is the only client.

### Superseded interim work

The uncommitted C form-decode layer is dropped: `cbits/microhttp_http.c/.h`,
`Http.formFieldsBytes`/`decodeFormBytes`/`normaliseFormNewlines`, their unit
tests, and the Makefile `HTTP_OBJ` plumbing. Kept: the CRLF-normalisation
seam test (it pins the form path), the ByteString-native handler plumbing
where it is verb-agnostic (`writeDocumentBytes`, `saveStatusFragment` removal
makes this moot), and `bench/FormDecodeBench.hs` with its C strategy removed
(the C numbers live in this RFC's Context). The `spawnAndWait`/`posix_spawn`
work (ADR-078) is unrelated and stays.

## Alternatives Considered

- Keep the C decode shim (works, measured 380x faster than the best Haskell
  arrangement): rejected as the end state because it keeps string
  manipulation in C when the encoding step can simply be removed; the raw
  body is faster still.
- Pure-Haskell decode (String, ByteString loop, chunk-wise, memchr-assisted):
  measured 19ms-7.3s per 80KB decode against 0.05ms in C; interpreted
  per-byte work cannot approach native speed, and prose escape density makes
  chunking ineffective (`make bench-form-decode`).
- Patch MicroHs with native `elemIndex`/linear `concat` and decode chunk-wise:
  the memchr-FFI simulation still measured 55ms (worse than the String
  pipeline); only a native decode-loop primitive would help, which is the C
  shim relocated.
- JSON save payloads (`{markdown, images}`): JSON string unescaping is
  another per-byte decode of the whole body; same disease.
- Multipart form bodies (raw part for markdown, fields for image titles):
  avoids the decode but requires writing a multipart parser (per-byte
  boundary scanning) into the framework; the `?image-titles` controller is
  strictly smaller.
- WebDAV `MOVE`/`Destination` for move: non-standard method vocabulary,
  rejected by `parseMethod` by design, and the two-phase dry-run/confirm
  contract is controller-shaped anyway.
- Keeping htmx for autosave with `hx-encoding` tweaks: htmx forms are
  urlencoded by design; raw bodies mean owning the request, at which point
  htmx contributes only a debounce attribute.

## Security Impact

- No authentication exists; the author-identity header seam (RFC-0032) is
  unchanged and applies to `PUT`/`DELETE` exactly as to POST.
- Raw bodies remove urlencoding ambiguity; the body size limit
  (`formBodyLimit`) still bounds every write. Argument-vector process
  execution (ADR-070/ADR-078) is unaffected.
- CSRF exposure is unchanged (no cookies or sessions; single-user tool).
- Path handling continues through `resolveStaticPath`; the new `/drafts/`
  routes must apply the same traversal validation as `/documents/`.

## Reliability Impact

- Autosave becomes idempotent-by-contract (`PUT`), so client retries after
  timeouts are safe; the save controller keeps its dirty/saving/saved state
  machine and its failure surface (themed notices, client-error reports).
- Removing the per-save decode eliminates the measured 10-25s GC pauses
  (autosave allocation drops from ~115MB to body-ingest cost; publish loses
  the decode share of ~197MB).
- One new failure mode: the publish-then-image-titles pair is two requests;
  a failed second request leaves `images.yaml` one sync behind, which the
  next publish repairs (the sync is update-only and idempotent). This is no
  worse than today's behaviour when a save succeeds and a later one fails.
- The no-JS floor keeps working through the unchanged form path.

## Compatibility Impact

- Internal only: the editor is the sole client of the removed POST routes
  (`?publish`, `?discard-draft`, `?delete`); they are removed without
  aliases. Any personal scripts driving those routes must switch verbs.
- `scripts/hang-repro.sh` drives publishes via `?publish` and must be updated
  with the new verb in the same change.
- The urlencoded form POST to `/documents/*path` (the no-JS floor) is
  unchanged, including CRLF normalisation. The raw-HTML save guard retires
  with flat mode (the tree trusts first-party documents, per the existing
  `treeSave` contract).
- Retiring flat mode makes `document_tree_root` required: a config without it
  now fails at startup with a clear message instead of silently serving the
  flat store. The `document_root` and `attachment_root` keys are removed.
- Editor bundle: htmx leaves the page; `markdown-editor.js` gains the
  debounced save fetch. No editor content-format change (RFC-0017 pipeline
  untouched).

## Testing and Quality Gates

- `make check` (docs, format, lint, unit + integration suites, editor checks,
  chrome gates) before and after every phase.
- New integration seam tests are listed per phase below; the existing save
  seam tests (byte-exact UTF-8, CRLF form normalisation, draft resume,
  publish-commits-and-clears-draft) must survive unchanged or move verb.
- `bun run editor:test` for the save-controller rewrite;
  `make test-editor-browser` for an end-to-end autosave/publish smoke pass.
- `make bench-form-decode` still builds after the C strategy is removed.
- A `scripts/hang-repro.sh` storm run (search-enabled rig) as the perf
  acceptance check: no HANG, no CRASH, and no SLOW (GC pause) events.

## Rollout Plan

### Phase 1: Flat-Mode Retirement

- [x] Test: starting with an empty `document_tree_root` fails with a clear
      configuration error (replacing the silent flat fallback).
- [x] Remove the flat routes, handlers, `DocumentStore`, the flat attachment
      store and routes, the raw-HTML guard and `validationStatusFragment`,
      and the `maybeError` threading in `editorPage`; relocate the
      `Verso.Attachment` helpers the tree uses.
- [x] Remove the flat branches from the editor element (`isTreeMode` guards
      that exist only to skip flat mode).
- [x] Remove `document_root`/`attachment_root` config keys; delete the flat
      unit specs and `AttachmentSpec` coverage that has no tree counterpart.
- [x] `make check` green; tree-mode integration suite unchanged.

### Phase 2: Framework Verb Plumbing

- [x] Test: RouterSpec routes a `PUT` request to a `Router.put` route and a
      `DELETE` request to a `Router.delete` route (given/when/then form).
- [x] Add `Router.put`; confirm `DELETE` routing needs no framework change.

### Phase 3: Draft Resource Endpoints

- [x] Test: `PUT /drafts/sec/page.md` with a raw body stores the draft
      byte-exact (including bytes that would be mangled by urldecoding, e.g.
      `+` and `%20` literals).
- [x] Test: `PUT /drafts/<path>` refuses an unsafe path (traversal) exactly
      as `/documents/` does.
- [x] Test: `DELETE /drafts/sec/page.md` removes the draft; the next edit
      view no longer resumes it.
- [x] Test: editing a page after `PUT /drafts/...` resumes the draft (the
      RFC-0032 resume contract holds through the new route).
- [x] Implement the `/drafts/*path` PUT/DELETE handlers (versioning mode
      only; 404 otherwise).

### Phase 4: Publish, Delete, and Image-Title Verbs

- [x] Test: `PUT /documents/sec/page.md` (raw body) writes the page
      byte-exact, records a commit with the author identity, and clears the
      draft.
- [x] Test: a second identical `PUT /documents/...` yields no new commit
      (idempotency contract).
- [x] Test: `PUT /documents/...` in non-versioned tree mode writes the live
      page directly (no commit machinery).
- [x] Test: `DELETE /tree/sec/page.md` moves the page to trash, appends to
      the operation log, and commits -- the existing `?delete` seam tests
      move to the new verb.
- [x] Test: `POST /documents/<path>?image-titles` updates `images.yaml`
      short titles (the existing image-title-on-save test moves here).
- [x] Implement `PUT /documents/*path`, `DELETE /tree/*path`, and the
      `?image-titles` controller; remove `?publish`, `?discard-draft`, and
      `?delete` routes and their handler branches.

### Phase 5: Editor Fetch Writes and htmx Removal

- [ ] Editor test: the save controller debounces `editor:changed` and issues
      `PUT /drafts/...` with the raw document, transitioning
      dirty -> saving -> saved (and -> failed on error).
- [ ] Editor test: publish issues `PUT /documents/...` then the
      image-titles controller call (only when page-relative images exist),
      then navigates.
- [ ] Editor test: discard issues `DELETE /drafts/...`; nav-tree delete
      issues `DELETE /tree/...`.
- [ ] Remove the htmx script tag, the `hx-*` form attributes, and the
      `htmx:*` listeners; keep the form + `<noscript>` submit +
      `ElementInternals` for the no-JS floor.
- [ ] Remove `isHtmxRequest` save/publish branches, `saveStatusFragment`,
      and the `HX-Redirect` arm of `clientRedirect`; `treeSave` keeps only
      the form branch.
- [ ] `make test-editor-browser` autosave/publish smoke passes without htmx.
- [ ] Update `scripts/hang-repro.sh` to the new verbs; storm run shows no
      HANG/CRASH/SLOW.

### Phase 6: Supersede the C Decode Layer and Record Decisions

- [ ] Remove `cbits/microhttp_http.c/.h`, the `HTTP_OBJ` Makefile plumbing,
      `Http.formFieldsBytes`/`decodeFormBytes`/`normaliseFormNewlines` and
      their unit tests; restore the String `formFields` path for the
      remaining small urlencoded bodies; keep the CRLF seam test green.
- [ ] Trim `bench/FormDecodeBench.hs` to the Haskell strategies; record the
      C measurements in this RFC only.
- [ ] ADR: the interaction model (server-rendered pages, fetch commands,
      resource verbs vs POST controllers, no-JS form floor); note RFC-0035's
      htmx open question as closed by removal.
- [ ] Update CONTEXT.md language entries touched by the route changes
      (Draft, Publish) and the decision register.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts
  do not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- None open. Resolved during review (2026-07-12): flat mode is retired
  outright as Phase 1 (superseding the earlier assumption that it would keep
  its urlencoded fetch POST save), and nothing besides the editor exercises
  the removed `?publish`/`?discard-draft`/`?delete` routes, so they are
  removed without aliases.
