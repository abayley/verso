---
id: RFC-0014
name: Zero-Copy File Responses
status: Draft
owners:
    - alistair
created: 2026-06-14
updated: 2026-06-14
supersedes: []
superseded_by: null
---

# Zero-Copy File Responses

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-06-14 |
| Started   |            |
| Completed |            |

## Summary

Add a `FileBody FilePath` constructor to `ResponseBody` whose contents are sent
straight from the filesystem to the socket by the kernel via `sendfile(2)`,
with no copy through the server's address space. Because `sendfile` needs the
file size up front, this also gives file responses an exact `Content-Length`
(closing the deferred file-size gap and making them keep-alive-eligible). The
response writer's sink grows a file-send capability alongside its chunk writer,
and static serving (RFC-0010) switches its body to `FileBody` for the fast
path. The bytes bypass userspace, so a `FileBody` cannot be transformed or
counted by `egress` middleware -- an inherent property of zero-copy that is
made explicit.

## Context

Static files today stream through `StreamBody (fileEnumerator path)`:
`fileEnumerator` reads 4 KiB chunks into `ByteString`s and `send`s each one, so
every byte is copied kernel -> userspace -> kernel. For large assets that is
wasted work the kernel can do itself. `sendfile(2)` -- Linux, macOS/BSD, and
Windows `TransmitFile` -- copies a file descriptor to a socket descriptor
in-kernel; it is the standard static-serving fast path (nginx, Apache).

It also resolves threads we parked. `sendfile` (and the `lseek`/`fstat` needed
to size the transfer) gives an exact byte count, so a `FileBody` response can
carry a real `Content-Length` -- the open review item that the `mhs`
`getFileSize` being unavailable had blocked -- which in turn makes such
responses keep-alive-eligible (length-delimited rather than close-delimited).

The catch is structural: the response writer is built around a chunk writer
(`ResponseWriter = ByteString -> IO (Either StreamError ())`), and a file send
has no chunks to hand it. So the sink must grow a file-send operation, and --
because the head must carry the file's `Content-Length`, which is known only
after the file is opened and sized -- the file case is owned end to end by the
sink, not split across the abstract `writeResponse`.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- A `FileBody FilePath` response body sent with `sendfile(2)`, no userspace
  copy, integrated with non-blocking writes (readiness, RFC-0005) and the idle
  write timeout (RFC-0008).
- An exact `Content-Length` for file responses, from the file size.
- Static serving (RFC-0010) uses `FileBody` as its fast path.
- The behaviour degrades safely: a non-macOS platform, an `egress` transform,
  or a `sendfile` that cannot start falls back to the existing
  `StreamBody (fileEnumerator …)` path.

## Non-Goals

- No `Range`/partial-content responses yet; `sendfile` takes an offset and
  length, so the design does not preclude them, but they are a later RFC.
- Keep-alive itself stays out (RFC-0012 non-goal); `FileBody` merely becomes
  eligible by gaining a `Content-Length`. `Connection: close` is still sent.
- No in-process body transforms (compression) at all; that is the proxy's job
  (ADR-031). An `egress` stage cannot rewrite a `FileBody` in place, but it may
  replace the body to opt out of zero-copy if it ever needs to.
- Non-macOS platforms are out of initial scope; the `sendfile` signature
  differs and lives behind the portability seam (RFC-0007).

## Proposal

### The response body and the sink

```haskell
data ResponseBody
    = StrictBody ByteString
    | StreamBody (Enumerator StreamError ())
    | FileBody FilePath                       -- sent via sendfile(2)

-- the writer's sink grows a file-send op beside the chunk writer
data ResponseSink = ResponseSink
    { sinkChunk :: ByteString -> IO (Either StreamError ())  -- head, strict, stream
    , sinkFile  :: Response -> FilePath -> IO (Either StreamError ())
    }
```

`writeResponse` dispatches: `StrictBody`/`StreamBody` go through `sinkChunk` as
now; `FileBody path` delegates the whole response to `sinkFile response path`.
`sinkFile` owns the file case end to end because the head needs the size:

1. open the file read-only (bracketed -- closed on every exit path);
2. `lseek` to `SEEK_END` for the size (no `fstat`/`struct stat` layout needed);
3. serialise the head with `Content-Length: <size>` (a new
   `serialiseFileHead :: Response -> Int -> ByteString`) and send it with the
   chunk path;
4. `sendFileWithin` the body from the file fd to the socket;
5. close the file fd.

The socket sink implements `sinkFile` with `sendfile`; the in-memory/test sink
implements it by reading the file and using `sinkChunk` (a non-zero-copy
fallback that keeps `writeResponse` testable off a socket).

### The socket primitive

```haskell
-- loop over partial sends, parking on write-readiness, bounded by the idle
-- write timeout -- the sendfile mirror of sendAllWithin (RFC-0008)
sendFileWithin :: Int -> ClientSocket -> Fd -> Offset -> Length
               -> IO (Either SocketError ())
```

On a non-blocking socket `sendfile` sends a partial amount and reports it; on a
would-block it returns `EAGAIN` with the bytes-sent count, and we advance the
offset, park on `waitForWriteFD` (bounded by the timeout), and retry until the
length is exhausted. A hard error after the head is on the wire aborts the
connection, exactly as a chunk write failure does.

### Existence and the 404

The existence and directory checks stay in `serveStatic` (RFC-0010,
`doesFileExist` / `doesDirectoryExist`), which decides 404 before returning a
`200` `Response` with a `FileBody`. The `sinkFile` open is then a fast path; on
the rare time-of-check/time-of-use failure (the file vanished between the check
and the write) it aborts the connection, like a mid-stream `StreamSourceError`
today. (An alternative -- the sink opening before the head and emitting its own
404 -- is in Open Questions.)

### Content-Length, keep-alive, and egress

The `lseek` size yields an exact `Content-Length`, so a `FileBody` response is
length-delimited. `Connection: close` is still sent (keep-alive is a separate
RFC); when keep-alive lands, `FileBody` responses are already eligible.

Because the bytes go kernel-to-kernel, they never pass through userspace, so an
`egress` stage cannot rewrite them *in place*. That is not a prohibition,
though: a middleware that sees a `FileBody` and wants to act on the content
simply **replaces the body** with a `StrictBody` or `StreamBody` it builds from
the file -- explicitly opting that one response out of zero-copy -- and a
middleware that does not care passes the `FileBody` through untouched. So a
hypothetical compression middleware would swap a `FileBody` for a compressing
`StreamBody`; the logging middleware, which only observes, leaves it a
`FileBody` and records the response size from the `Content-Length` instead of
counting chunks. The body type the writer finally sees decides the send path:
still a `FileBody` -> `sendfile`; swapped -> the normal copy/stream path. (In
practice MicroHttp compresses nothing in process -- that is the proxy's job,
ADR-031 -- so this is a capability, not a planned use.)

### Static serving

`Static.serveStatic` returns `FileBody (root <> safe path)` instead of
`StreamBody (fileEnumerator …)`. Its path-safety and existence/directory checks
are unchanged; only the body source changes, gaining zero-copy and an exact
`Content-Length`.

`StreamBody (fileEnumerator …)` remains a supported, public response body
(decided): it is the portable path (non-macOS), the path an `egress` stage can
fuse onto directly, and the fallback when `sendfile` cannot be used (including
the body an `egress` stage swaps a `FileBody` for when it wants the content).
`FileBody` is the fast path, not a replacement.

## Alternatives Considered

- Keep only `StreamBody (fileEnumerator …)`: simple and portable, but copies
  every byte through userspace and cannot supply a `Content-Length` without a
  size syscall. `FileBody` is the fast path; the enumerator path stays as the
  fallback.
- Size via `fstat` and a `struct stat` offset peek (and let the sink open
  before the head and emit its own 404, removing `serveStatic`'s check): more
  unified, but `struct stat` layout is fragile and platform-specific, whereas
  `lseek` needs no struct. Rejected in favour of `lseek` plus `serveStatic`'s
  existing check.
- macOS `sf_hdtr` to send the head and file in one syscall: a micro-optimisation
  that does not port to Linux's `sendfile`; send the head with the chunk path,
  then `sendfile` the body, uniformly.

## Security Impact

- The served path is already constrained by `serveStatic` (RFC-0010): per-
  segment rejection of `.`/`..`/separators, directories refused. `FileBody`
  changes only how the bytes leave, not which file is chosen.
- The symlink-escape limitation from RFC-0010 carries over unchanged (no
  `realpath`); a `FileBody` will happily `sendfile` a symlink target.
- A slow reader on a large file is bounded by the idle write timeout
  (RFC-0008) through `sendFileWithin`, so a `FileBody` is not a new
  resource-exhaustion vector.

## Reliability Impact

- The file fd is bracketed and closed on success, error, and timeout.
- A partial `sendfile` loops on readiness; a hard error after the head is sent
  aborts the connection (the head is already committed, like a streamed body
  that fails mid-flight).
- A `sendfile` that cannot start (open failure, unsupported platform) falls
  back to the chunked `fileEnumerator` path or aborts, never hangs.

## Compatibility Impact

- `ResponseBody` gains a `FileBody` constructor; every exhaustive match on
  `ResponseBody` (the serialisers, `writeResponse`, the `Eq`/`Show` instances,
  middleware `fuseBody`) must handle it. `Eq`/`Show` for `FileBody` compare/
  show the path.
- `ResponseWriter` (a bare function) becomes the `ResponseSink` record;
  `writeResponse`'s signature changes. Internal -- callers are the server and
  tests.
- New FFI: `sendfile`, `lseek`, `open`/`close` for the source file, behind the
  socket layer's existing platform seam (macOS first).

## Testing and Quality Gates

- `make check` stays green.
- Integration (loopback): a `FileBody` for a known file returns `200` with the
  exact `Content-Length` and the file's bytes; a large file (bigger than the
  socket buffers) streams fully and is bounded by the write timeout when the
  reader stalls; a missing file is a `404` via `serveStatic`.
- Unit: `serialiseFileHead` emits the status, headers, and `Content-Length`;
  the in-memory `sinkFile` fallback reads a temp file and reproduces its bytes.
- The existing static-serving tests (RFC-0010) keep passing with the body
  switched to `FileBody`.

## Rollout Plan

1. Phase one: the primitive and the body.
   - [ ] `sendFileWithin` (and the `sendfile`/`lseek` FFI) in
         `MicroHttp.Network.Socket`.
   - [ ] `FileBody` constructor; `serialiseFileHead`; `ResponseSink` with
         `sinkChunk` + `sinkFile`; `writeResponse` dispatch.
   - [ ] Socket `sinkFile` (open, size, head, sendfile, close); in-memory
         fallback `sinkFile`.
2. Phase two: adopt and verify.
   - [ ] `Static.serveStatic` returns `FileBody`; tests above; `make check`
         green.
   - [ ] ADR for the zero-copy file body and the `egress` opacity rule; note in
         the network design and the request-lifecycle walkthrough.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- Should the sink open the file *before* the head and emit its own `404` on an
  open failure or a directory (removing `serveStatic`'s existence check), or
  keep the check in `serveStatic` and have the sink abort on the rare TOCTOU?
  Leaning: keep the check in `serveStatic` (it also rejects directories cleanly
  and keeps 404 policy out of the socket sink); the sink aborts on TOCTOU.
- Does `lseek` for the size interact badly with anything that later wants to
  re-read the fd? The body send uses `sendfile`'s own offset argument, so the
  `lseek` is only to learn the size; no re-read is needed.
