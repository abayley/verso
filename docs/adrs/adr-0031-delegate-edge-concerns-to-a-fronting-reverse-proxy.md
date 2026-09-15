---
id: ADR-0031
name: Delegate Edge Concerns To A Fronting Reverse Proxy
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0031: Delegate Edge Concerns To A Fronting Reverse Proxy

## Context

MicroHttp is designed to run behind a reverse proxy (nginx or similar)
in production. A cluster of edge concerns are handled better, and more
securely, at that proxy than in a small MicroHs server, and building them in
process would bloat the server for no gain on the proxied path. We choose
explicitly which of these we will not build, so the boundary is a decision
rather than a backlog.

## Decision

The following are the proxy's responsibility and are deliberately not
built into MicroHttp: TLS termination; HTTP/2 and HTTP/3 (the upstream link
stays HTTP/1.1); client keep-alive (we send `Connection: close` per response,
matching nginx's default connection-per-request upstream mode -- RFC-0012
non-goal); body compression such as gzip or brotli (we never compress a
response body in process, which is also why a `sendfile` `FileBody` being
opaque to `egress` costs nothing -- RFC-0014); static asset caching and CDN
edge; request rate limiting and per-IP connection caps; and slow-client /
connection-flood (slow-loris) edge protection. MicroHttp keeps a lightweight
backstop for proxy-less deployments only: the idle read and write timeouts
(ADR-0027, ADR-0028) bound a single stalled connection and
`settingsMaxActiveHandlers` caps concurrency, but the fuller edge protection is
the proxy's. The boundary is documented in
`docs/architecture/starter-design.md` (Reverse Proxy Boundary).

## Consequences

the server stays small and close-per-request, and a proxied
deployment gains TLS, keep-alive, compression, caching, and slow-loris
protection without any of that code in MicroHttp. Proxy-less deployments (local
development, the desktop packaging) run without those, retaining only the
timeout backstop -- acceptable for trusted or low-exposure use. Because nothing
is compressed in process, an `egress` middleware that ever wants to transform a
`FileBody` opts out of zero-copy by replacing the body (RFC-0014) rather than
the framework needing a compression path. Should a proxy-less production target
ever become first-class, keep-alive and the heavier protections would need
their own RFCs.
