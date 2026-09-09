---
id: ADR-0034
name: Zero-Copy File Responses Via sendfile, With The Size Carried
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0034: Zero-Copy File Responses Via sendfile, With The Size Carried

## Context

Static files streamed through `StreamBody (fileEnumerator path)`,
copying every byte kernel -> userspace -> kernel and (ADR-0030) carrying no
`Content-Length` because `mhs` exposes no `getFileSize`. `sendfile(2)` copies a
file descriptor to a socket in-kernel and, with the file size, gives an exact
length.

## Decision

Add `FileBody FilePath Int` to `ResponseBody` -- the path and its size
in bytes. The size is resolved once, where the body is built: `serveStatic`
already stats for the 404 decision, so it also sizes the file (via `lseek` to
`SEEK_END`, the single new size FFI, exposed as `fileSizeBytes`) and carries the
result on the constructor. Both the response head's `Content-Length` and the
access-log byte count read that one carried number, with no second syscall. The
response writer grows from a bare `ResponseWriter` into a `ResponseSink` with a
`sinkChunk` (head/strict/stream) and a `sinkFile`; the socket `sinkFile` opens
the file, writes the head with the carried size, `sendfile`s the body bounded by
the idle write timeout (`sendFileWithin`, mirroring `sendAllWithin`), and closes
the fd. The in-memory test sink reads the file and replays it through
`sinkChunk`. Because the bytes go kernel-to-kernel, an `egress` stage cannot
rewrite a `FileBody` in place; `fuseBody` passes it through, and a middleware
that wants the content replaces the body with a `StreamBody`/`StrictBody`. The
portable, transformable fallback `StreamBody (fileEnumerator …)` stays public.
macOS only initially (the `sendfile` signature differs on Linux -- the RFC-0007
seam). The design is RFC-0014.

## Consequences

Static responses are zero-copy and length-delimited, closing the
deferred `Content-Length` gap and making file responses keep-alive-eligible (when
keep-alive lands; `Connection: close` still sent). The RFC's original plan had
the sink `lseek` for the size; carrying it on the body instead gives a single
source of truth shared by the head and the log without the log re-opening the
file. `Range`/partial content and Linux `sendfile` are later work. The
symlink-escape limitation (ADR-0030) is unchanged.
