---
id: ADR-0082
name: The Browser Owns Visual Themes
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0082: The Browser Owns Visual Themes

> Status: Accepted (2026-08-06).

## Context

The visual theme contract grew beyond the three registration points
accepted in ADR-0036. Haskell owns an allowlist, a default, labels, page
attributes, and standalone page controls. TypeScript owns another theme list,
another label map, and theme-specific behaviour. The copies can drift, and a
new theme requires changes in server code even though visual themes affect
only browser presentation. RFC-0015, RFC-0016, and RFC-0035 record the earlier
contracts and remain historical records.

## Decision

The browser owns visual themes through one authored TypeScript
registry. The registry owns theme ids, labels, the explicit `shadcn` default,
browser capabilities, optional document activation, preference storage, and
the `data-editor-theme` root attribute. Editor controls, standalone page
controls, Studio surfaces, and Moebius assets use the registry without
comparing theme names.

The editor build also creates a small classic script from the registry. Every
editor and standalone page loads the script synchronously before its
stylesheets. The script resolves `editor-theme` and `editor-color-scheme` from
browser storage and updates the document root before first paint. The normal
deferred bundle then installs interactive controls and theme capabilities.

Haskell no longer owns theme ids, labels, validation, a theme default, theme
controls, or a theme-specific page attribute. The public `editor_theme`
configuration key and its `VERSO_EDITOR_THEME` environment overlay are
retired. No Haskell projection, neutral manifest, registry request, or server
rendered theme metadata replaces them. CSS remains handwritten, with an
automated check that its nondefault theme selectors match the registry.

## Consequences

Adding an ordinary theme requires one registry record and one
CSS block. A page with JavaScript applies stored preferences before first
paint and receives interactive controls from the deferred bundle. A page
without JavaScript uses the Shadcn root styles and has no interactive
appearance controls. Existing browser preferences keep the `editor-theme` and
`editor-color-scheme` storage keys. The first-visit theme can no longer be set
by the server.
