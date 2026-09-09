---
id: ADR-0044
name: Editor View Preferences Persist Client-Side In localStorage
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0044: Editor View Preferences Persist Client-Side In localStorage

## Context

The editor carries view preferences that should survive across sessions
-- the colour scheme (light/dark/match-system), the visual theme (ADR-0036), and
now an adjustable editing-column width (Narrow/Medium/Wide/Full, since the fixed
default felt narrow). These are presentation choices with no bearing on document
content. The question for the width preference (and the pattern in general) was
where to keep it: a cookie (sent to the server) or client-side storage.

## Decision

persist editor view preferences client-side in `localStorage`, one
key per preference (`editor-color-scheme`, `editor-theme`, `editor-body-width`),
read on editor init and written on change through small accessors that tolerate an
unavailable or throwing `localStorage`. No cookie, and the server is not involved.
The width preference is applied as a `data-body-width` attribute the stylesheet
keys off (a `max-width` per preset, with "Full" also lifting the page's centred
max-width); the colour scheme and theme are applied as attributes likewise.

## Consequences

a cookie would only earn its place if the server needed the value
at render time -- to emit the right markup server-side and avoid a first-paint
flash. But rendering is browser-owned and the no-JavaScript path is raw Markdown
(ADR-0040), so these are pure client concerns; a cookie would add a server
round-trip and a contract for no benefit. The trade-off accepted is that the page
loads with defaults and the JS applies the stored preference (a brief flash is
possible), and that preferences are per-browser, not per-user-account (there is no
account model -- ADR-0031). New view preferences follow the same one-key pattern.

Extends ADR-0036 (editor visual themes) to the persistence question and applies it
to the width preference; consistent with ADR-0040 (browser-owned rendering).
