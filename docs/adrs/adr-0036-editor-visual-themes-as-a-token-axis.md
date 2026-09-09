---
id: ADR-0036
name: Editor Visual Themes As A Token Axis
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0036: Editor Visual Themes As A Token Axis

## Context

The Markdown editor had one appearance axis -- light/dark, toggled by
`wa-light`/`wa-dark` on `<html>`. Its surface is already token-driven (a full
set of `--markdown-editor-*` custom properties under `:root` and `:root.wa-dark`
in `markdown-editor.css`), and a round of redesign mockups (`docs/mockups/`)
showed several distinct looks worth offering. The goal was to make the editor
themeable without coupling a visual choice to the light/dark axis or to new
editor behaviour.

## Decision

Add a `data-editor-theme` attribute on `<html>` as a visual-theme axis
orthogonal to the colour scheme. A theme overrides the `--markdown-editor-*`
tokens for both schemes (`:root[data-editor-theme="x"]` and its `.wa-dark`
variant), with an optional structural-CSS layer scoped under the same selector
for effects tokens cannot express (gradients, glass, grids, ruled paper, status
chrome). An absent or unknown value is the default Paper look, so existing
behaviour is unchanged. A `wa-dropdown` in the toolbar selects the theme; the
theme and the colour scheme persist in `localStorage`, resolved (validated) on
connect, and a pre-paint inline bootstrap applies the stored preference before
first paint from a fixed allowlist so there is no flash. An `editor_theme`
config key (RFC-0011) supplies the first-visit default; precedence is stored
preference, then config default, then Paper, validated server-side to Paper. A
theme may also set a small set of bounded layout presets the editor already
supports (Workbench opens in Split; the source pane's line numbers come from
CodeMirror's `basicSetup`); presets are defaults, not locks. The initial set is
Paper, Aurora (neutral frosted glass), Blueprint (cyanotype/white-print grid),
Herbarium (ruled-paper journal), and Workbench (IDE). The design is RFC-0015.

## Consequences

themes are a thin, mostly-CSS axis layered on the existing token
and colour-scheme machinery, so adding one is a token block plus an optional
structural layer, registered in three places (the CSS, the editor dropdown list,
and the server allowlist); the pre-paint bootstrap's allowlist is derived from
the server list rather than duplicated. Genuinely new interactions are
out of scope for a theme: Studio (mockup C) -- defined by a selection bubble
toolbar and a slash-command menu -- is deferred to a later round (the parked Lit
spike) rather than shipped as a half-version. `backdrop-filter` themes degrade
to flat translucency where unsupported.
