---
id: ADR-0042
name: Attachments As A Content-Addressed Blob Store Served As Untrusted Bytes
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0042: Attachments As A Content-Addressed Blob Store Served As Untrusted Bytes

## Context

RFC-0018 adds images and file attachments. The editor needed a way to
get binary bytes from the user to the server and reference them from Markdown,
but the only `POST` body the app parsed was `application/x-www-form-urlencoded`
(the document save), and raw HTML stays uniformly rejected (ADR-0040/0041), so
`<img>`/`<a>` tags are not an option. Serving untrusted user bytes safely is the
sharp edge: an uploaded HTML or SVG blob served inline as same-origin content is
the classic stored-XSS vector. The existing static serving (ADR-0018/0030/0034)
already had the safe, zero-copy half of the problem solved.

## Decision

(1) Upload is a raw-body `POST /attachments` from the editor's `fetch`
(the `File` is the body; the filename rides a percent-encoded
`X-Attachment-Filename` header), not multipart -- multipart needs a streaming
boundary parser for a scripted interaction, and the existing bounded
`readBodyStrict` reader is reused unchanged. No-JavaScript upload is deferred
(no-JS users reference already-uploaded URLs by typing). (2) Storage is a
content-addressed blob store mirroring `DocumentStore`: bytes are written once to
`<root>/<hash>` under a non-cryptographic 128-bit FNV-1a hash (MicroHs has no
crypto library); the write is direct, not temp-then-rename (no `renameFile` in
MicroHs), which content-addressing makes idempotent and self-healing. The
original filename is *not* stored -- it travels in the serving URL
(`/attachments/<hash>/<name>`) where it drives the content type and the download
name, keeping the store a pure blob directory with no parallel index. (3) Serving
is the proven zero-copy `FileBody`/`sendfile` path plus a fixed hardening header
set on every response: the URL-derived `Content-Type`, `X-Content-Type-Options:
nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`, immutable
caching (safe because content-addressed), and `Content-Disposition: inline` only
for the inline-renderable image types (png/jpeg/gif/webp) with `attachment`
(download) for everything else -- SVG included, since it can carry script. The
hash segment is validated as 32 lowercase hex digits; the cosmetic name never
touches the filesystem, so `Static`'s path-safety is preserved. A type allow-list
gates uploads (`415` otherwise) and a per-upload size bound returns `413`; the
global framing cap `settingsMaxBodyBytes` was raised to at least that bound.

## Consequences

the server now accepts and serves arbitrary user bytes -- a new
trust boundary -- but the bytes can neither execute nor be re-interpreted
(nosniff + sandbox CSP + download disposition for non-image types), cannot
overwrite or escape (content-addressing + hex-validated path), and are bounded in
size and type. The hash is for dedup and addressing, not security -- safety is the
serving headers and the allow-list, so a non-cryptographic hash is acceptable.
Orphaned blobs (a document edited to drop an image) are tolerated in v1; a
mark-sweep GC over documents' referenced hashes, and quotas/rate-limiting (in-app
or via the fronting proxy, ADR-0031), are deferred. Images render from Markdown
`![]()` via a content extension (ADR-0041); no raw HTML is introduced, so the
save-time guard is unchanged.

Extends ADR-0034 (zero-copy `sendfile`) and ADR-0030 (safe static serving) to a
write path; rides ADR-0014 (filesystem-backed stores) and ADR-0031 (edge concerns
at the proxy). Consistent with ADR-0040/0041 (raw HTML stays rejected).
