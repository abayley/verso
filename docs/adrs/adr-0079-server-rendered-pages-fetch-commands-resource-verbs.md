---
id: ADR-0079
name: Server-Rendered Pages, Fetch Commands, Resource Verbs
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0036]
---

# ADR-0079: Server-Rendered Pages, Fetch Commands, Resource Verbs

> Status: Accepted (RFC-0036, 2026-07-12).

## Context

The htmx autosave form was the last htmx consumer, and its
hypermedia payload was already discarded (`hx-swap="none"`); every other
operation was a plain fetch. Urlencoding the page body for that form
cost ~80-115MB of interpreted decode per save (the GC-pause
investigation), and a measurement spike (bench/FormDecodeBench.hs)
showed no Haskell arrangement on mhs approaches native decode speed.
Sending the body raw removes the decode entirely, which means owning
the request -- the natural moment to adopt honest verbs. Flat mode
retired first (one serving mode).

## Decision

The interaction model is: server-rendered HTML documents for
reads and navigation (the URL is the state; view transitions are
navigations); editor-owned fetch commands for mutations, answered with
status codes and small JSON, never HTML fragments; custom elements own
client state (dirty/saving/saved, panels); a plain form POST -> 303 ->
GET remains the no-JavaScript floor. State transfer uses resource
verbs -- `PUT /drafts/*path` (autosave, raw body, idempotent),
`DELETE /drafts/*path` (discard), `PUT /documents/*path` (publish, raw
body, idempotent: unchanged bytes commit nothing), `DELETE /tree/*path`
(delete to trash) -- while domain operations with plans, revisions, or
log appends stay POST controllers (create, `?move`, `?rollback`,
`/undo`, `/trash/*id`, `?asset`, `?image-titles`). Page bodies travel
as `text/markdown` raw request bytes, stored verbatim (ADR-0038); CRLF
normalisation is a form-path property only. The image-title sidecar
sync moved off the save payload to its own small controller.

## Consequences

htmx is removed entirely (RFC-0035's vendor-or-CDN open
question closes by deletion), and the interim C form-decode shim was
never needed -- nothing on the save hot path decodes at all. Old
`?publish`/`?discard-draft`/`?delete` routes were removed without
aliases (the editor is the only client). The browser smoke drives the
tree mode on its own port; test/bench/hang-repro.sh uses the new verbs.
