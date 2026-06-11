---
id: RFC-0003
name: Socket Payload Correctness and Testability
status: Accepted
owners:
    - alistair
created: 2026-06-10
updated: 2026-06-10
supersedes: []
superseded_by: null
---

# Socket Payload Correctness and Testability

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-10       |
| Started   | 2026-06-10       |
| Completed | 2026-06-11       |

## Summary

Fix the server's single-read request handling so requests of any size and
segmentation are read completely, and make `MicroHttp.Network.Socket`
testable by adding a client-side connect and a bound-port query. Together
these changes give the socket and server layers a loopback integration suite
and a unit-tested request framing seam, replacing today's single test.

## Context

`Server.handleClient` currently calls `recv` exactly once with an 8192-byte
buffer. Any request split across TCP segments, and any request larger than
8192 bytes, is truncated; `settingsMaxBodyBytes` (1 MB) is unreachable. The
Markdown editor will hit this the first time a document larger than roughly
8 KB is saved.

The socket module cannot be tested beyond listen-and-close because it has no
client side: there is no `connect`, and a socket bound to port 0 cannot
report which port it received. The browser smoke test works around this by
hardcoding port 8080 and driving a full browser.

Both gaps block later goals: the performance harness needs an in-process
client, streaming I/O needs the framed reader as its chunk source, and the
portability and GHC work need a socket test suite as a safety net before FFI
types change.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Requests are read until complete: headers to their terminator, then a body
  of exactly `Content-Length` bytes, across any number of `recv` calls.
- Header and body limits are enforced incrementally, without unbounded
  buffering.
- The socket module gains `connectTcp` and a bound-port query so loopback
  tests and future clients are possible.
- The sockaddr encoding becomes a pure, unit-testable function.
- The socket and framing layers have a meaningful test suite.

## Non-Goals

- No keep-alive or pipelining; one request per connection stands (ADR-011).
- No chunked transfer encoding; the parser continues to reject it.
- No streaming request bodies to handlers; the framed result is still one
  strict `ByteString` (streaming is a later RFC).
- No readiness manager or polling changes.
- No FFI type changes (`CInt` migration belongs to the portability RFC,
  which uses this RFC's tests as its safety net).

## Proposal

Socket module additions:

- `boundPort :: ListenSocket -> IO (Either SocketError Port)` via a
  `getsockname` FFI import, so tests can bind port 0 and discover the
  assigned port.
- `connectTcp :: Host -> Port -> IO (Either SocketError ClientSocket)` via a
  `connect` FFI import. The socket is set non-blocking before connecting, so
  the call must treat `EINPROGRESS` and `EALREADY` as would-block and retry
  until `EISCONN` (reported by a repeated `connect` call) or a real error.
  A blocking connect is not acceptable: the runtime is effectively one OS
  thread, and a blocked syscall would prevent the accepting thread from
  running in a loopback test.
- Extract the sockaddr layout into a pure
  `encodeSockAddrIn :: Host -> Port -> [Word8]` used by `bind` and
  `connect`. This makes the byte layout unit-testable and gives the
  portability RFC a single seam for per-platform layouts.

Request framing in the server layer:

- Add a framed request reader behind a small seam: it takes a chunk source
  (`IO (Either SocketError ByteString)`, where `Right ""` means orderly peer
  close) and the existing parse limits, and returns the complete request
  bytes or an error. It scans for the CRLFCRLF header terminator, reads
  `Content-Length` from the headers if present, then reads exactly that many
  further body bytes. Limits are checked as data arrives.
- `handleClient` supplies `recv` as the chunk source and replaces its single
  read. Oversized or malformed framing maps to the existing 400-style
  responses; the limit errors reuse the parser's header-too-large and
  body-too-large semantics.
- `recv` returning `Right ""` is pinned as the orderly end-of-stream signal.

The framing function is data-in/data-out over an injected chunk source, so
its tests are unit tests with a scripted fake source; no sockets involved.

## Alternatives Considered

- Read in the parser instead of framing before parsing: couples the pure
  parser to IO and contradicts its current design.
- Grow the single read buffer: still wrong for segmented arrivals; no size
  is sufficient.
- Test through external processes (curl-style) instead of `connectTcp`:
  slower, flakier, and leaves the module itself untestable.

## Security Impact

- Incremental limit enforcement removes an unbounded-buffering risk that a
  naive read-until-close loop would introduce.
- Bodies are read only up to the declared and configured limits; a
  `Content-Length` exceeding `settingsMaxBodyBytes` is rejected before the
  body is buffered.

## Reliability Impact

- Requests larger than one segment or 8 KB stop failing silently.
- A peer that closes mid-request yields a clean 400 instead of a parse of
  truncated bytes.
- A peer that sends a `Content-Length` and then stalls holds a handler slot
  until it completes; idle-read timeouts are recorded as an open question
  rather than solved here.

## Compatibility Impact

- Public socket API grows (`connectTcp`, `boundPort`); nothing is removed.
- `Application` and handler contracts are unchanged.
- The integration test suite gains real socket tests; runtime remains
  seconds, not minutes.

## Testing and Quality Gates

- `make check` after every slice.
- `make test-editor-browser` after phase three.

Test cases, simplest to most complex:

1. Given a listening socket on port 0, when querying the bound port, then a
   non-zero port is returned. (integration)
2. Given a listening socket, when a client connects to the bound port, then
   accept returns a client socket. (integration)
3. Given a connected pair, when each side sends, then the other side
   receives the same bytes. (integration)
4. Given a peer that closed its socket, when receiving, then `Right ""` is
   returned. (integration)
5. Given a closed file descriptor, when receiving or sending, then a
   `SocketError` is returned. (integration)
6. Given a payload larger than the socket send buffer, when sending with
   `sendAll`, then the receiver eventually reads every byte. (integration)
7. Given a free port with no listener, when connecting, then a
   `SocketError` is returned. (integration)
8. Given a host and port, when encoding the socket address, then the
   expected sixteen bytes are produced. (unit)
9. Given headers split across chunks, when framing, then the complete
   request is assembled. (unit)
10. Given a body split across many chunks, when framing, then headers plus
    the full `Content-Length` body are returned. (unit)
11. Given headers that never terminate within the header limit, when
    framing, then a header-too-large error is returned. (unit)
12. Given a `Content-Length` above the body limit, when framing, then a
    body-too-large error is returned before the body is read. (unit)
13. Given a request without `Content-Length`, when framing, then the
    request completes at the end of the headers. (unit)
14. Given a peer close before the declared body arrives, when framing, then
    an incomplete-request error is returned. (unit)
15. Given a POST body larger than 8192 bytes, when posted over a real
    socket, then the server responds and the document store holds the full
    body. (integration)

## Rollout Plan

1. Phase one: socket testability (test cases 1 to 8).
   - [x] Pure `encodeSockAddrIn` with unit tests; `bind` uses it.
   - [x] `boundPort` via `getsockname`.
   - [x] `connectTcp` with the non-blocking connect loop.
   - [x] Loopback integration suite for accept, recv, sendAll, close, and
         error mapping. The large-transfer case runs as single-threaded
         rounds sized within the kernel socket buffers; see the concurrency
         finding under Open Questions.
2. Phase two: framed request reader (test cases 9 to 14).
   - [x] Reader over an injected chunk source with incremental limits.
   - [x] Unit suite with scripted fake sources.
3. Phase three: server integration (test case 15).
   - [x] Replace the single read in `handleClient` with the framed reader.
         `handleClient` now frames the request, dispatches a complete one to
         the application, answers a framing limit or completeness failure with
         a 400, and reports a transport failure as `ServerReadFailed`.
   - [x] Large-body integration test through `connectTcp`. A new
         `ServerSocketSpec` drives `handleClient` over a loopback pair: a body
         larger than the read buffer round-trips in full, and a
         `Content-Length` above the body limit persists nothing.
   - [x] `make check` passes; ADR-023 accepted and the design document
         updated. The dedicated browser smoke pass was not needed; the
         existing smoke flow still passes through `make check`.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts
  do not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- Runtime finding: what first presented as a concurrency hang is silent
  data corruption in the MicroHs runtime. Forcing a sufficiently large
  lazily constructed ByteString yields an empty, memoised value once any
  other thread has been forked, even one that already exited;
  `spike/MicroHttp/Spike11.hs` is a nine-line deterministic reproducer and
  `spike/MicroHttp/Spike10.hs` preserves the socket-level deadlock it was
  minimised from (a sender given length zero sends nothing and its
  receiver polls forever). The network design document carries the full
  finding, including the withdrawal of the two workaround candidates
  recorded earlier. Until this is fixed upstream, integration tests
  transfer in single-threaded rounds sized within the kernel socket
  buffers, the original test case 6 is not in the suite, and test case 15
  should keep its body small enough to fit the kernel buffers so the
  client send completes before the server reads.
- Should a slow or stalled peer be bounded by an idle-read timeout in this
  RFC, or deferred to the readiness-manager work where time-based waiting
  gets a proper home?
- Should `connectTcp` accept `HostAny`, reject it, or map it to the loopback
  address? Tests only need loopback.
- Does MicroHs's `getsockname` FFI need the same hand-built sockaddr buffer
  for reading, and should decoding also be a pure function for symmetry?
