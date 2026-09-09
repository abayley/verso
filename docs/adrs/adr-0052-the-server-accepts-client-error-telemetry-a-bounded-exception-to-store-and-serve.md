---
id: ADR-0052
name: The Server Accepts Client-Error Telemetry (A Bounded Exception To Store-And-Serve)
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0052: The Server Accepts Client-Error Telemetry (A Bounded Exception To Store-And-Serve)

## Context

ADR-0019 keeps the server minimal -- it stores and serves Markdown
documents and static assets, and does not process application events. The editor
gained a global error boundary (RFC-0022) that surfaces unexpected client
failures to the user as a banner, but once the tab closes there is no record an
operator can inspect: failures are invisible in aggregate. The blank-page class
of bug (e.g. the bare-image/callout crash) is exactly the kind that needs
after-the-fact visibility once the editor points at the live documentation tree
with real authors. Capturing that requires the server to receive something other
than a document.

## Decision

add a single write-only telemetry endpoint, `POST /client-errors`, as
a deliberate, bounded exception to ADR-0019. It accepts a small
form-urlencoded **client-error report** (message, bounded stack, page path,
kind), stamps it server-side (timestamp, peer, user-agent), escapes every value
logfmt-safely, and appends one line to a dedicated **client-error log**
(`client_error_log`), separate from the access log. It returns `204` and is
fire-and-forget. "Sentry-like" means the operational outcome -- queryable error
visibility -- not the Sentry protocol or any outbound integration; the server
gains no network egress and no new external dependency. The report carries no
page body content and no user identity (privacy). The endpoint is unauthenticated
and assumes a trusted/internal deployment, matching the editor's context; the
body is size-capped and the client de-duplicates and caps reports per session,
but there is no server-side per-IP rate limiting (the growth path -- an
`MVar` token bucket created at startup and shared via closure capture -- is
recorded but not built). The flat and tree modes both expose the route.

## Consequences

the server now has exactly one endpoint that is neither a document
nor a static asset, and it writes application-supplied data to disk -- a real
departure from ADR-0019, scoped to a single bounded, write-only, no-read endpoint
so the store-and-serve thesis otherwise holds. Operators gain a greppable
client-error log; the no-JavaScript reader produces none (telemetry is a client
concern). Refines ADR-0019 (the exception) and builds on RFC-0022 (the boundary
that feeds it) and ADR-0053 (the log it writes to rotates). The endpoint is
unauthenticated by design; if the deployment ever faces untrusted networks, the
recorded server-side rate-limiting path must be built. RFC-0023 implements this.
