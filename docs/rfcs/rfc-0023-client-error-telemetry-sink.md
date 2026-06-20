---
id: RFC-0023
name: Client-error telemetry sink
status: Draft
owners:
    - alistairbayley
created: 2026-06-20T23:40+12:00
updated: 2026-06-20T23:40+12:00
supersedes: []
superseded_by: null
---

<!-- PLACEHOLDER RFC. Parked intent, not yet designed. Captures the decision to
defer server-side client-error telemetry so the choice is recorded rather than
forgotten. Do not implement from this document; it needs a design pass first. -->

# Client-error telemetry sink

| Stage     | Timestamp          |
|-----------|--------------------|
| Authored  | 2026-06-20 23:40   |
| Started   |                    |
| Completed |                    |

## Summary

Persist unexpected client-side editor errors somewhere an operator can see them
after the fact -- "Sentry-like" operational telemetry -- so silent failures in
the browser are observable in aggregate, not just surfaced to the one user who
hit them. This is the deferred third tier of the editor's error-handling plan
(see RFC-0022): tier 1 (browser console) and tier 2 (a user-visible banner via
the editor's global error boundary) ship with that RFC; this RFC owns tier 3.

## Context

RFC-0022 adds a top-level error boundary to `<markdown-editor>` that catches
otherwise-silent failures and shows the user a dismissible banner, logging to
the browser console. That closes the silent-failure hole for the person at the
keyboard, but leaves the operator blind: there is no record of what failed,
how often, or on which page, once the tab is closed.

The deferral is deliberate. A server-side sink adds an HTTP endpoint and
app-logic surface that cuts against ADR-019's minimal-server ethos (the server
stores and serves documents and assets; it does not process application
events). It only pays off once the editor points at the live documentation tree
with real authors and an operator who needs post-hoc visibility -- which is not
yet the case. This document parks the intent at a stable address so it is not
lost.

## Goals

- Make unexpected client errors observable to an operator after the session
  ends (frequency, page, error shape).
- Stay within the project's minimal-server, single-binary, MicroHs-runtime
  constraints (no external telemetry service required for the base case).
- Reuse the existing logfmt access-log vocabulary (`MicroHttp.Log`) where it
  fits, rather than inventing a parallel logging stack.

## Non-Goals (for now)

- Full third-party APM/Sentry integration as a hard dependency.
- Client performance metrics, session replay, or breadcrumbs.
- User-identifying telemetry of any kind.

## Proposal

To be designed. Sketch only: a narrow `POST` endpoint that accepts a bounded,
structured error payload from the editor's global error boundary and appends it
to a client-error log (its own file, or a tagged stream in the access log).
The endpoint is rate-limited and size-capped; payloads carry no document
content and no user identity.

## Alternatives Considered

- To be filled in during the design pass (e.g. console-only forever; a hosted
  Sentry SDK; a self-hosted collector; piggy-backing the access log vs a
  dedicated log).

## Security Impact

- A new unauthenticated write endpoint is an abuse surface (log flooding,
  injection into log lines). Needs rate-limiting, size caps, and logfmt-safe
  escaping.
- Payloads must exclude document content and any personal data (privacy rules:
  no sensitive data in error reports).

## Reliability Impact

- The sink must be best-effort: a failing telemetry POST must never degrade the
  editor or block a save. Fire-and-forget from the client.

## Compatibility Impact

- Additive: a new endpoint plus a client emitter. No change to the document
  HTTP/storage contract.

## Testing and Quality Gates

- `make check`
- Endpoint tests (rate-limit, size cap, logfmt escaping) once designed.

## Rollout Plan

1. Design pass: resolve the Open Questions, choose endpoint/log shape.
2. Server endpoint + log sink.
3. Client emitter wired to the RFC-0022 error boundary.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop, add the
  smallest missing decision to `## Open Questions`, and continue only after
  explicit approval.

## Open Questions

- Dedicated client-error log file, or a tagged stream in the existing access
  log?
- What is the minimal, privacy-safe payload (message, stack, page path, editor
  build id)? How is a stack trace bounded?
- Rate-limiting and de-duplication strategy (per-session cap? server-side
  coalescing of identical errors)?
- Does "Sentry-like" mean an actual Sentry-compatible ingestion format, or just
  the operational outcome (aggregated, queryable error visibility)?
- Should this ever run in the no-JavaScript path? (Likely no -- it is a client
  concern by definition.)
- Retention and rotation for the client-error log.
