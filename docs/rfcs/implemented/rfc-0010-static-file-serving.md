---
id: RFC-0010
name: Static File Serving
status: Implemented
owners:
    - alistair
created: 2026-06-12
updated: 2026-06-12
supersedes: []
superseded_by: null
---

# Static File Serving

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-12       |
| Started   | 2026-06-12 23:39 |
| Completed | 2026-06-12 23:39 |

## Summary

Add a library static-file handler that serves files from a root directory
under a URL prefix, reached by a new terminal wildcard route in the router.
It maps the request path to a filesystem path under the root with
traversal-safe per-segment sanitisation, checks that the target exists and
is a regular file before committing any response head (so a missing path is
a clean 404, never a 200 that fails mid-stream), chooses a Content-Type by
file extension, and streams the file close-delimited. It replaces the
hand-rolled whitelist in `TestApp`. The server stands alone without a proxy;
an nginx or CDN front end can still shadow the route in production.

## Context

Static serving is broadly useful: local development, the desktop-app
packaging on the backlog, and deployments with no reverse proxy. Today the
library has no generic static handler; `TestApp` hand-rolls a three-entry
whitelist (`staticEditorAsset`) with hardcoded filenames and content types,
which does not generalise and carries no path-safety story for an arbitrary
root.

Generalising it safely needs four things the current code does not have:
prefix routing, path sanitisation, a 404 decided before the response head,
and a content-type map. The pieces to build on exist: `fileEnumerator`
streams a file in bounded chunks and owns its handle, `doesFileExist` and
`doesDirectoryExist` are in the `mhs` `System.Directory`, and `requestPath`
is already a list of percent-decoded segments.

Two environment facts shape the scope. First, `getFileSize` is commented
out in the `mhs` `System.Directory` and no `hFileSize` is exposed, so a
`Content-Length` would require a new stat/size FFI. This RFC therefore
streams close-delimited (no `Content-Length`), consistent with the server's
existing `Connection: close` model, and defers length-delimited responses,
keep-alive, and conditional requests to a later RFC that adds the FFI.
Second, `pathSegments` splits the raw path on `/` and only then
percent-decodes each segment, so `%2e%2e` arrives as a literal `..` segment
and `%2f` decodes to a `/` inside a single segment rather than a separator.
The sanitiser must account for both, which is the security crux below.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- A `static` route constructor and `serveStatic` handler that serve files
  from a root directory under a URL prefix.
- A terminal wildcard segment in the router so a prefix route matches an
  arbitrary remaining path.
- Path-traversal safety: no request can read outside the root, and
  directories are never listed or served.
- A missing target, a directory, or an unsafe path yields a clean 404
  before any 200 head is written.
- Content-Type chosen by file extension, defaulting to
  `application/octet-stream`.
- `TestApp` migrated off its whitelist onto the new handler, with the
  existing editor-asset tests still green.

## Non-Goals

- No `Content-Length`, `Range`, conditional requests
  (`If-Modified-Since`/`ETag`), or keep-alive; the body streams
  close-delimited. These wait on a stat/size FFI in a later RFC.
- No directory index (`index.html`) and no directory listing.
- No symlink-escape detection beyond rejecting `..`; detecting a symlink
  inside the root that points outside it needs a `realpath`/stat FFI and is
  a documented limitation.
- No content compression; that is egress middleware.
- Does not remove the option of fronting the server with nginx or a CDN; a
  production deployment may still shadow the static route.

## Proposal

- Router: add a terminal wildcard `PathPart`, `Rest String`. The pattern
  syntax `*name` parses to `Rest name` (alongside `:name` for `Capture`); a
  `Rest` part must be last. In `matchPath`, a `Rest name` matches all
  remaining segments (including none) and records the capture. The capture
  value is informational; the handler builds the path from `requestPath`
  segments (below), not from a re-joined capture string, so an embedded
  separator cannot be reintroduced.
- A new module `MicroHttp.Static`:
  - `static :: String -> FilePath -> Route` -- the smart constructor:
    `static prefix root` builds `Router.get (prefix ++ "/*rest")` wired to
    `serveStatic` with the segment count of `prefix` and the `root`.
  - `serveStatic` derives the file path from the request's decoded
    `requestPath`, dropping the prefix segments. Each remaining segment is
    one path component; it is rejected if it equals `.` or `..`, is empty,
    contains a path separator (`/` or `\`, the `%2f` case), or contains a
    NUL. Any rejection answers 404. The surviving components are joined onto
    the root.
  - Existence and type are checked before the head: `doesFileExist` must be
    true and `doesDirectoryExist` false; otherwise 404. Only a regular file
    yields a 200 whose body is `StreamBody (fileEnumerator path)` with a
    `Content-Type` from the extension map and the server's existing
    `Connection: close` head.
  - An extension-to-MIME map covers the common types (`.html`, `.css`,
    `.js`, `.json`, `.svg`, `.png`, `.jpg`/`.jpeg`, `.gif`, `.woff2`,
    `.txt`, `.ico`), defaulting to `application/octet-stream`.
- `TestApp`: replace the `staticEditorAsset` whitelist route with
  `static "/static/editor" "static/editor"`. The `.js` and `.css` content
  types come from the map (`text/javascript`, `text/css`), so the editor
  script and Web Awesome stylesheet still return a streaming static
  response and the existing tests hold.

## Alternatives Considered

- Static serving as middleware (try the filesystem, else fall through to
  the app): makes routing implicit and order-sensitive and hides the static
  mount from the route table. Serving a file for a path is dispatch, so an
  explicit route reads better.
- Leaving static serving to nginx only: the library would not stand alone
  for local development, desktop packaging, or proxy-less deployments.
  Rejected as the sole answer, but kept compatible -- the route can be
  shadowed by a proxy in production.
- `Content-Length` now via `hFileSize`/`getFileSize`: not exposed by the
  `mhs` libraries (`getFileSize` is commented out, no `hFileSize`), so it
  would need a new FFI. Deferred to keep this RFC's scope to safe serving.
- Keeping the per-handler whitelist: does not generalise, repeats the
  content-type wiring per asset, and gives no traversal story for an
  arbitrary root.

## Security Impact

- Path traversal is the primary risk and the reason for the RFC. The path
  is built from already-decoded `requestPath` segments, each rejected if it
  is `.`/`..`, empty, contains a separator, or contains a NUL. Because the
  parser splits on `/` before decoding, `%2e%2e` is a literal `..` segment
  (rejected) and `%2f` decodes to a `/` within one segment (rejected as an
  embedded separator). No component can ascend, so the resolved path stays
  within the root.
- Directories are never listed or served: a directory target is a 404.
- Symlink escape: a symlink inside the root pointing outside is not
  detected without a `realpath`/stat FFI. This is a documented limitation;
  operators should not place untrusted symlinks in a served root. A future
  FFI-backed RFC can canonicalise and confine.
- Dotfiles: `..` is rejected, but a leading-dot file such as `.env` in the
  root would be served if present (see Open Questions). Serving is by an
  explicit root the operator controls.
- An unsafe path answers 404 rather than 403, so the response does not
  confirm whether a guarded path exists.

## Reliability Impact

- Time-of-check/time-of-use: a file may be removed between the existence
  check and the open. `fileEnumerator` already ends the stream with a
  `StreamSourceError` if the open fails, which closes the connection; this
  is a rare mid-stream abort, not a crash.
- Files stream in the existing bounded chunk size, so memory stays bounded
  regardless of file size.
- Without `Content-Length`, the response is close-delimited and the client
  detects completion by EOF, consistent with the server's current model.

## Compatibility Impact

- The router gains a `Rest` `PathPart` and the `*name` pattern syntax; this
  is additive and existing `:name`/literal patterns are unchanged.
  `PathPart` is internal (not exported), so there is no external break.
- `MicroHttp.Static` is a new module; nothing existing changes shape.
- `TestApp`'s `/static/editor/*` behaviour is preserved at runtime (same
  files, same content types, same streaming response). Its tests did change,
  though: the 404-before-head check stats the filesystem, so routing a static
  request is now an IO action, and the editor-asset serving tests moved from
  the unit suite (which forbids filesystem effects) to integration, using the
  committed `markdown-editor.css` (the `.js` and `webawesome.css` assets are
  build artifacts and may be absent).

## Testing and Quality Gates

- `make check` stays green.
- Router unit: `/static/*rest` matches `/static/a/b.css` capturing the
  remainder, matches an empty remainder, and treats `Rest` as terminal.
- Static unit (pure): per-segment sanitisation rejects `..`, `.`, empty, a
  separator-bearing segment, and NUL; the extension map returns the right
  type and falls back to `application/octet-stream`.
- Static integration: an existing file returns 200 streaming with the right
  content type and exact bytes; a missing file, a directory, and a
  traversal attempt (`..` and `%2e%2e`/`%2f` forms) each return 404 and read
  nothing outside the root.
- TestApp: the editor script and Web Awesome stylesheet still return a
  streaming static response (existing tests).

## Rollout Plan

1. Phase one: routing and the static handler.
   - [x] `Rest` wildcard `PathPart` and `*name` syntax in `MicroHttp.Router`
         with matching tests.
   - [x] `MicroHttp.Static` with `static`, `serveStatic`, per-segment
         sanitisation, the extension map, and the 404-before-head check.
   - [x] Migrate `TestApp` off `staticEditorAsset` onto `static`.
   - [x] Unit and integration tests above; `make check` green.
   - [x] Flip ADR-0030 to accepted; note it in the relevant design document.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should `serveStatic` reject path components beginning with a dot by
  default (hiding `.env`, `.git`, and similar), or serve whatever the
  operator places in the root? Rejecting is safer by default; serving is
  more predictable. Leaning toward serving, since the root is explicit, with
  a note that operators must curate it.
- When do length-delimited responses, keep-alive, and conditional requests
  (`ETag`/`If-Modified-Since`) land? They depend on a stat/size FFI and the
  resolution of the open "local file-size FFI" review item, so they belong
  in a separate RFC rather than this one.
