---
id: ADR-0030
name: Static File Serving As A Safe Wildcard Route
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0030: Static File Serving As A Safe Wildcard Route

## Context

Static serving was a hand-rolled whitelist in TestApp
(`staticEditorAsset`), with no generic handler and no path-safety story for an
arbitrary root. A general handler needs prefix routing, path-traversal safety,
a 404 decided before the response head, and a content-type map. Two
environment facts shaped the scope: `getFileSize` is not exposed by the `mhs`
libraries, so a `Content-Length` would need a new FFI; and the parser splits
the path on `/` before percent-decoding each segment, so `%2e%2e` arrives as a
literal `..` segment and `%2f` decodes to a `/` inside a single segment.

## Decision

Add a terminal wildcard `PathPart` (`Rest`, pattern `*name`) to the
router, capturing the remaining segments. `MicroHttp.Static` provides `static`
(a route constructor mounting a root under a prefix) and `serveStatic`. The
served path is built from the request's already-decoded `requestPath` segments
beyond the mount, not from a rejoined capture, and each component is rejected
if it is empty, `.`, `..`, or contains a path separator or NUL -- which
defeats both literal and `%2e%2e`/`%2f` traversal. Existence is checked with
`doesFileExist` and `doesDirectoryExist` before the head, so a missing file or
a directory is a clean 404, never a 200 head that fails mid-stream. The
content-type is chosen by extension (default `application/octet-stream`), and
the body streams close-delimited as a `StreamBody` over `fileEnumerator` (no
`Content-Length`). TestApp is migrated off the whitelist. The design is
RFC-0010.

## Consequences

A generic, traversal-safe static handler is reachable as an
ordinary route, and a reverse proxy can still shadow it in production. Because
the 404-before-head check stats the filesystem, routing a static request is
now an IO action; TestApp's editor-asset serving tests therefore moved from
the unit suite (which forbids filesystem effects) to integration. Deferred to
a later FFI-backed RFC: `Content-Length`, keep-alive, conditional requests
(`ETag`/`If-Modified-Since`), and symlink-escape detection (which needs
`realpath`). A dotfile under the root is served if present, so the operator
must curate the served root.
