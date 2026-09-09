---
id: ADR-0048
name: Raw HTML Is Preserved, Not Rejected, In The Trusted Tree Mode
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0048: Raw HTML Is Preserved, Not Rejected, In The Trusted Tree Mode

## Context

ADR-0040/0041 uniformly reject raw HTML at save time, because the editor
served *untrusted, user-submitted* content (raw HTML = stored XSS). But the
document tree is the user's *own* first-party files, and ~half of them carry HTML
-- almost all of it export-metadata comments (`<!-- ... -->`), a few with visible
markup (MkDocs grid cards). The editor's strict parse throws on an `html` node, so
those documents could not be loaded or saved without error or loss. The trust
calculus that motivated the rejection does not hold for first-party files.

## Decision

in tree mode only, preserve raw HTML rather than reject it. An opt-in
`raw-html` content extension carries each `html` node (block or inline) through
verbatim and renders it *inert* -- shown escaped, never as live HTML -- so editing
a document neither loses nor executes its HTML; the editor registers it only when
the server marks tree mode. Both editing surfaces preserve it: source mode is
verbatim text, and the visual editor pre-extracts raw-HTML spans (by remark source
position) into sentinels before its Markdown loader (marked) can interpret or drop
them, then re-inserts them as inert raw-html nodes after load. The tree save path
drops the raw-HTML guard (the files are trusted and nothing renders the HTML as
live). The flat mode is unchanged: it still rejects raw HTML, and its parse still
throws on an `html` node.

## Consequences

first-party documents load, edit, and save -- in visual or source
mode -- without losing or executing their HTML, while the untrusted flat mode keeps
the ADR-0040/0041 trust boundary intact: the rejection moves from "always" to
"untrusted contexts only", matching the actual threat model. Nothing in the editor
renders raw HTML as live markup in either mode (it is inert when preserved), so no
execution surface is introduced. Refines ADR-0040/0041 (raw-HTML rejection is now
scoped to untrusted content); builds on ADR-0041's content-extension registry.
