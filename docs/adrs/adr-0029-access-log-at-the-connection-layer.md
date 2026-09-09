---
id: ADR-0029
name: Access Log At The Connection Layer
status: Superseded
owners:
    - Alistair Bayley
supersedes: []
superseded_by: ADR-0032
related_rfcs: []
---

# ADR-0029: Access Log At The Connection Layer

## Context

The server emitted nothing observable per request. An access log
needs both the request line (method, path) and the write outcome (status,
bytes, latency, and whether the connection failed). These live at different
layers: the application middleware (`Application -> Application`) sees the
head but runs only after the head parses, so it never observes a connection
that stalls or resets mid-headers and cannot guarantee a line per
connection. `handleClient` is the outermost layer and reaches a terminal
outcome for every accepted connection, so it is the only layer that can log
all of them. A wall-clock millisecond source (`getTimeMilli`) is available
in the `mhs` lib, adequate for latency.

## Decision

Put the access log at the connection layer. `handleClient` times
the request, captures the parsed head via an `onHead` callback the pipeline
runs on a successful parse, counts the bytes `socketResponseWriter` sends,
and emits a `RequestReceived` event when the head parses and a terminal
event after the write: `RequestCompleted` (with the written status,
including the 400/408 paths) for a sent response, or `RequestAborted` for a
transport failure, so no connection is unlogged. The logger is an injected
`AccessEvent -> IO ()` sink with a swappable formatter (`formatLogfmt` the
logfmt default); `settingsLogger` defaults to `nullLogger` (off). The
`MicroHttp.Log` module depends only on `MicroHttp.Http`, so `AccessEvent`'s
abort case carries a short String label rather than the server's
`ServerError` -- the server imports `MicroHttp.Log` for the `Settings`
field, and carrying `ServerError` would make that an import cycle. The
design is RFC-0009.

## Consequences

Every accepted connection produces a terminal log line, and a
parsed request also produces a received line, giving a standard access log
once an operator supplies a logger. `Settings` drops its unused
`deriving (Eq, Show)` because a `Logger` is a function; nothing in the
project compared or showed a `Settings`. When no logger is set the added
cost is two `getTimeMilli` reads and a byte counter per request, behind the
disabled path; the logger is off by default so the prior behaviour and the
benches are unchanged. The peer address (a `getpeername` FFI) and a
timestamp field are deferred to the injected sink or a follow-up.

Follow-up: every logfmt line now leads with a local-time timestamp,
`ts=YYYY-MM-DDThh:mm:ss.mmm±zzzz`, captured by `logfmtTo` at emit and rendered
by `localTimestamp`. It uses a `localtime`/`strftime` FFI rather than `Data.Time`
on purpose: the bundled `time` package compiles under `mhs` but its local-time
conversion is wrong on this toolchain (it negates the zone offset, e.g. NZST
renders as `-1200` with the wrong calendar day), whereas `localtime` delegates
to libc and is correct.
