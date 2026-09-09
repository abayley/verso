# ADR Registry Open Review Items

Point-in-time follow-up items carried over from the old single-file ADR register.
Not part of the generated register; kept for continuity.

- Verify socket layout assumptions on non-macOS platforms before treating
  Haskell-side sockaddr construction as portable.
- Resolved (2026-06-15, ADR-0038): MicroHs `ByteString` is acceptable. The
  corruption fault is fixed in 0.16.3.0 (suite green;
  `docs/microhs-bytestring-bug-report.md`), and the RFC-0013 spike showed
  packing/append/coalescing perform well; the HTML renderer now builds on
  `ByteString`. Socket read/write throughput is still tracked by the socket
  benches.
- Port `sendfile` to Linux (different signature) and add `Range`/partial-content
  and conditional requests (`ETag`/`If-Modified-Since`) for file responses; the
  exact `Content-Length` from the file size is now in place (ADR-0034, RFC-0014).
- Resolved (2026-06-16, ADR-0040): the TestApp has no server-side Markdown
  renderer to remove; rendering stays browser-owned and no-JavaScript reading is
  raw Markdown. The save-time validation is retained as a trust-and-integrity
  guard, not a renderer.
