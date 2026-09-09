---
id: ADR-0040
name: No-JavaScript Reading Is Raw Markdown; Rendering Stays Browser-Owned
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0040: No-JavaScript Reading Is Raw Markdown; Rendering Stays Browser-Owned

## Context

RFC-0001 (ADR-0039) added a no-JavaScript editing fallback: without
scripting, a document is edited as raw Markdown in a textarea and read as raw
Markdown (the `GET /documents/:id` response is `text/markdown`). The question
arose whether to extend the fallback to a *formatted reading* view, which would
require turning Markdown into HTML on the server -- a second renderer alongside
the browser's. The server currently has no Markdown-to-HTML renderer at all
(ADR-0019): it serves Markdown raw and only validates it on save.

## Decision

Keep the no-JavaScript experience as raw Markdown end to end; do not
add a server-side Markdown renderer. Rendering stays browser-owned (ADR-0019
reaffirmed). Without JavaScript, MicroHttp is a raw-Markdown CRUD app; with
JavaScript, it is the rich editor -- a consistent progressive-enhancement seam.
The server's save-time Markdown validation (raw-HTML rejection, supported-block
subset check) is retained as a trust-and-integrity guard, not a renderer: it
defends against untrusted client input and keeps stored documents within the
editor's round-trippable subset. There is therefore nothing to "remove" -- the
server has no renderer, and the validation stays.

## Consequences

one Markdown renderer in the system (the browser's), forever; no
divergence risk and no cross-language sync burden. The no-JavaScript reader (a
marginal audience: scripting off, very old browsers, some text-mode/privacy
setups) sees legible raw Markdown rather than formatted HTML, an honest
degradation that matches Markdown's plain-text legibility. This holds only while
the no-JavaScript *reader* is a graceful-degradation case rather than a
first-class user; if formatted server-rendered reading ever becomes a product
requirement (a content/publishing thesis where readers without JavaScript are
first-class), that is a different product and warrants its own RFC, with the
server renderer kept in sync with the editor subset through a shared golden
corpus.

Alternatives considered:

- A server-side Markdown-to-HTML renderer (option B in the discussion): rejected.
  It is a second implementation of the editor's Markdown subset across a language
  boundary mhs cannot bridge (it cannot run the JS renderer), so it must be kept
  in sync by hand; the sync tax is permanent and grows with every editor feature
  (tables, etc.). A shared golden corpus makes it *manageable*, not free, and it
  cuts against the editor-as-island direction (ADR-0019/ADR-0031).
- Persisting client-rendered HTML at save time (option C): rejected. A
  no-JavaScript save stores Markdown the client renderer never processed, so the
  cached HTML drifts from the Markdown with no way to self-heal; a cache that can
  go stale and cannot recover is worse than no cache.
