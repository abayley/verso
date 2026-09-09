# HTTP Request-Rate Benchmark

A quick end-to-end measure of how many requests per second the TestApp server
handles, and how the in-memory builder path compares with the zero-copy
`sendfile` path (RFC-0014). Run it with:

```sh
make bench-http
# or: bash scripts/http-bench.sh
```

Knobs (environment variables): `MICROHTTP_BENCH_PORT` (default 8099),
`MICROHTTP_BENCH_CONC` (default 16), `MICROHTTP_BENCH_N_SMALL` (3000),
`MICROHTTP_BENCH_N_LARGE` (800). The script builds the executable, starts it on
a private port with its own config (your `micro-http.conf` and port 8080 are
left alone), drives it with ApacheBench, and stops it.

## Method

- Driver: ApacheBench (`ab`), new connection per request (the server sends
  `Connection: close`; keep-alive is a non-goal, ADR-0031).
- Four endpoints: `GET /` (the `Html.hs` builder, a `StrictBody`), a
  byte-identical snapshot of `/` served from disk (a `FileBody` via `sendfile`),
  an ~8 KB CSS, and an ~1.5 MB JS (both `FileBody`). The snapshot isolates
  builder-vs-`sendfile` from payload size.

## Representative results

macOS arm64 (Darwin 25.5), MicroHs 0.16.0.0, loopback, `c=16`. The server and
`ab` share the host and MicroHs is interpreted, so these are **relative**
figures, not production numbers.

| Endpoint                      | Body path              | Size    | Req/s      | Transfer  |
|-------------------------------|------------------------|---------|------------|-----------|
| `GET /`                       | `StrictBody` (builder) | 259 B   | ~1500-2000 | ~0.5 MB/s |
| `GET /…/_bench-snapshot.html` | `FileBody` (sendfile)  | 259 B   | ~1100-1400 | ~0.4 MB/s |
| `GET /…/markdown-editor.css`  | `FileBody` (sendfile)  | ~8 KB   | ~1250      | ~10 MB/s  |
| `GET /…/markdown-editor.js`   | `FileBody` (sendfile)  | ~1.5 MB | ~680-860   | ~1 GB/s   |

Latency for `GET /` at `c=16`: p50 ~8 ms, p90 ~19 ms, p99 ~37 ms. A concurrency
sweep (`c` = 1, 8, 32, 64) stays in the same throughput band at every level.

## Interpretation

- **CPU-bound on one core.** The MicroHs runtime is a single-threaded
  green-thread interpreter, so throughput is flat across concurrency -- extra
  connections queue behind the handler cap rather than adding throughput. The
  small-response ceiling (~2000 req/s) is per-request CPU cost (parse, framing,
  render, connection setup and teardown, the close drain), not a concurrency
  limit.
- **For tiny payloads the builder beats `sendfile`.** `StrictBody` is a single
  `send` of an in-memory buffer; `FileBody` costs `open` + `sendfile` + `close`.
  Zero-copy buys nothing when there is almost nothing to copy. This is exactly
  why static serving uses `FileBody` while small built pages stay `StrictBody`.
- **`sendfile` pays off on large files.** The ~1.5 MB asset streams at ~1 GB/s
  (kernel-to-kernel, no userspace copy, no per-chunk send loop) -- the win
  RFC-0014 was after. Per-request overhead dominates until tens of KB.
- **Zero failed requests at every size and concurrency.** This is independent
  confirmation that the graceful-close drain (ADR-0035) holds under sustained
  load: no truncation, no `RST`. The earlier flaky-under-load truncation would
  surface here as `ab` length or failed-request errors.
