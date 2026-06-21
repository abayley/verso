---
id: RFC-0023
name: Client-error telemetry sink
status: Draft
owners:
    - alistairbayley
created: 2026-06-20T23:40+12:00
updated: 2026-06-21T15:48+12:00
supersedes: []
superseded_by: null
---

<!-- Filename: rfc-0023-client-error-telemetry-sink.md -->

# Client-error telemetry sink

| Stage     | Timestamp          |
|-----------|--------------------|
| Authored  | 2026-06-20 23:40   |
| Started   |                    |
| Completed |                    |

## Summary

Persist unexpected client-side editor failures where an operator can see them
after the session ends. The editor's error boundary (RFC-0022) posts a small
**client-error report** to a new `POST /client-errors` endpoint; the server
stamps and escapes it and appends one logfmt line to a dedicated
**client-error log**, which rotates per RFC-0024. "Sentry-like" means the
operational outcome (queryable error visibility), not the Sentry protocol
(ADR-052).

## Context

RFC-0022 surfaces client failures to the user as a dismissible banner, but
nothing is recorded once the tab closes -- failures are invisible in aggregate,
exactly when the editor is about to point at the live documentation tree with
real authors. ADR-019 keeps the server to storing and serving documents; ADR-052
records the decision to add one bounded, write-only telemetry endpoint as a
deliberate exception. The server runs on MicroHs (no crypto, no outbound TLS) and
has no JSON parser, but has a urlencoded form parser (`formFields`), a
size-capped body reader (`readBodyStrict`), and a logfmt vocabulary
(`MicroHttp.Log`).

## Goals

- Capture unexpected client errors durably and greppably for an operator.
- Stay within the minimal single-binary server: no external service, no new
  runtime dependency, no network egress.
- Carry no page body content and no user identity.

## Non-Goals

- The Sentry protocol or any hosted/outbound integration (ADR-052).
- Server-side per-IP rate limiting (trusted-network assumption; growth path
  recorded in ADR-052).
- A no-JavaScript path (telemetry is a client concern).
- Log rotation itself -- owned by RFC-0024; this RFC consumes it.

## Proposal

### The client-error report (contract)

Client-sent, `application/x-www-form-urlencoded`:

- `message` -- error message, capped at 500 chars.
- `stack` -- stack trace, bounded to the first 20 frames and 2000 chars
  (whichever is hit first).
- `path` -- `window.location.pathname` only (no query string).
- `kind` -- `error` or `unhandledrejection`.

Server-stamped (trusted): `ts` (via `localTimestamp`), `peer` (connection host),
`ua` (`User-Agent` header). Every value is escaped logfmt-safely (quoting,
stripping newlines) before it joins the line -- unlike the access log, these are
untrusted.

### Server endpoint

- `POST /client-errors`, present in both flat and tree modes (a shared route).
- Body read with `readBodyStrict` capped at ~8 KB; parsed with `formFields`.
- Appends one logfmt line to the **client-error log** (`client_error_log`
  config key, default `build/client-errors.log`), a rotating file logger
  (RFC-0024).
- Returns `204 No Content`; fire-and-forget. Oversized/malformed requests are
  dropped (the size cap surfaces the standard error response, which the client
  ignores).

### Client emitter (wired into the RFC-0022 boundary)

- Fires from `showErrorBanner`, so every surfaced failure is also reported.
- De-duplicates within a session (keyed on message + first stack frame).
- Caps at ~10 reports per page load.
- Transport: `navigator.sendBeacon` with a `URLSearchParams` body (form-encoded,
  survives page unload, non-blocking); falls back to `fetch(..., {keepalive:true})`.

## Alternatives Considered

- Sentry-compatible ingestion / a hosted DSN: rejected (ADR-052) -- external
  protocol, network egress, no TLS on MicroHs, against ADR-019.
- Tagged stream in the access log: rejected -- a client error is application
  payload, not a connection event; folding it into `AccessEvent` blurs the
  middleware/handler boundary and pollutes the access-log vocabulary.
- JSON body: rejected -- no JSON parser on MicroHs; the urlencoded `formFields`
  parser already exists and is tested.
- Server-side rate limiting now: deferred -- disproportionate for a trusted
  internal deployment; the growth path is recorded.

## Security Impact

- A new unauthenticated write endpoint: an abuse surface (log flooding, log-line
  injection). Mitigations: ~8 KB size cap, logfmt-safe escaping of every
  client value, client-side dedup/session-cap, and rotation bounding disk
  (RFC-0024). Per-IP rate limiting is out of scope under the trusted-network
  assumption (ADR-052).
- Payloads exclude page body content and user identity; length caps bound any
  incidental leakage in a message or stack.

## Reliability Impact

- Best-effort and fire-and-forget: a failed report never degrades the editor or
  blocks a save. The endpoint does no work beyond append.
- Rotation (RFC-0024) bounds the client-error log's disk footprint.

## Compatibility Impact

- Additive: one new endpoint, one new config key, a client emitter. No change to
  the document HTTP/storage contract.

## Testing and Quality Gates

- `make check`.
- Server tests: the endpoint appends an escaped line; oversized bodies are
  rejected; logfmt-injection inputs are neutralised; non-POST/other methods are
  unaffected.
- Editor tests: the emitter dedups, respects the session cap, and posts on a
  boundary error (with `sendBeacon` stubbed).

## Rollout Plan

1. RFC-0024 (rotating logger) lands first -- the client-error log uses it.
2. Server endpoint: route, form parse, bound + escape, append to the rotating
   client-error log; config key; server tests.
3. Client emitter: `sendBeacon` transport, dedup, session cap, wired into the
   error boundary; editor tests.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or ADR-052 does not cover, stop,
  add the smallest missing decision to `## Open Questions` (or the owning ADR),
  with evidence, impact, options, and a recommendation, and continue only after
  explicit approval.

## Open Questions

- None outstanding; resolved during the RFC-0023 design grilling (see ADR-052).
