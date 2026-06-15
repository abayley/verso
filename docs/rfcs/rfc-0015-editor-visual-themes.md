---
id: RFC-0015
name: Editor Visual Themes
status: Draft
owners:
    - alistair
created: 2026-06-15
updated: 2026-06-15
supersedes: []
superseded_by: null
---

# Editor Visual Themes

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-06-15 |
| Started   | 2026-06-15 |
| Completed |            |

## Summary

Add a *visual theme* axis to the Markdown editor, orthogonal to the existing
light/dark colour scheme. A theme is a named set of the editor's
`--markdown-editor-*` design tokens (defined for both light and dark), an
optional block of structural CSS for effects tokens cannot express (gradients,
frosted glass, grids, chrome), and an optional small set of layout presets the
editor already supports (default view mode, status bar, line numbers, toolbar
placement). A dropdown in the toolbar selects the theme; the theme and the
colour scheme are persisted in `localStorage` and applied before first paint. A
config-file key supplies the default theme only when the visitor has no stored
preference. The initial set is the current look as the default ("Paper") plus
four drawn from the mockups: Aurora, Blueprint, Herbarium, and Workbench. Studio
(mockup C) is deferred until its bubble-toolbar/slash-menu interaction exists.

## Context

The editor already separates concerns the way themes need. The surface (page
background, document, floating toolbar pill, code blocks, blockquotes, save
states) is hand-styled from a complete set of `--markdown-editor-*` custom
properties in `static/editor/markdown-editor.css`, declared once under `:root`
(light) and again under `:root.wa-dark` (dark). Light/dark is the only current
axis: a radio group sets the scheme and `applyDocumentTheme()` toggles
`wa-light`/`wa-dark` on `<html>` (`markdown-editor-element.ts`). Web Awesome
supplies a second, independent layer (`wa-theme-*`/`wa-palette-*`/`wa-brand-*`
classes) that styles only the controls, not the surface.

Two rounds of redesign mockups exist in `docs/mockups/` (A to H, then I to M).
The chosen directions are Aurora Glass (J), Blueprint Drafting (I), Herbarium
(M), and Dark Workbench (B). The first three are visual-only and map directly
onto the token-plus-structural model. Workbench carries layout (status bar, a
default split, line numbers) that the editor already supports, expressed as
bounded presets. Workspace Studio (C) is deferred: its defining behaviour (a
selection bubble toolbar and slash-command menu) exceeds CSS and is the deferred
Lit spike, so it is left out of this round rather than shipped half-formed.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- A visual-theme axis independent of the light/dark colour scheme: every theme
  defines both a light and a dark token set, so the two controls never conflict.
- A clear contract a theme must satisfy: the full token set for both schemes,
  plus an optional structural-CSS layer and an optional set of bounded layout
  presets the editor already supports.
- A dropdown to choose the theme, with theme and colour scheme persisted and
  applied before first paint (no flash of the default).
- A config-file default theme that applies only when the visitor has no stored
  preference; precedence is stored preference, then config default, then Paper.
- An initial set: Paper (default), Aurora, Blueprint, Herbarium, and Workbench.
- Safe fallback: an unknown or unsupported theme resolves to Paper.

## Non-Goals

- Theming the non-editor TestApp pages (index, document view); editor only.
- User-authored or runtime-generated themes; the set is a fixed, code-defined
  list.
- New editor *interactions* introduced by a theme, and the Studio theme itself.
  Studio (mockup C) is defined by a selection bubble toolbar and a slash-command
  menu -- genuinely new behaviour (the deferred Lit spike) that exceeds CSS, so
  Studio is deferred to a later round and is not part of this RFC's deliverable.
  When it returns, its toolbar may sit below the workspace chrome if placing it
  inside proves awkward.
- Replacing Web Awesome's control theming; a theme may select a WA palette to
  harmonise the controls, but that is optional polish, not the mechanism.

## Proposal

### The theme axis

A single-valued attribute `data-editor-theme` on `<html>`, defaulting to
`paper`. An attribute (not a class) is used because only one theme is active at
a time and it must not collide with Web Awesome's `wa-theme-*` classes. The
colour scheme remains the `wa-light`/`wa-dark` classes, unchanged.

### The token contract

A theme must provide the full `--markdown-editor-*` token set for both schemes:

```css
:root[data-editor-theme="aurora"]          { /* light token values */ }
:root[data-editor-theme="aurora"].wa-dark  { /* dark token values  */ }
```

The default `paper` keeps the existing `:root` / `:root.wa-dark` blocks; an
absent or unknown attribute resolves to `paper`, so current behaviour is
unchanged when no theme is selected. The token list is the contract: a theme is
reviewed for completeness against it.

### The structural layer

Effects that are not colour (Aurora's gradient and `backdrop-filter` glass,
Blueprint's grid, Herbarium's ruled lines and margin illustration, Workbench's
status bar, Studio's sidebar and breadcrumb) are expressed as ordinary CSS
scoped under the theme selector:

```css
:root[data-editor-theme="aurora"] body.markdown-editor-page { background: <gradient>; }
:root[data-editor-theme="aurora"] .markdown-editor__toolbar--commands { backdrop-filter: blur(20px); }
```

This is a sanctioned, bounded extension: it stays scoped to the theme selector
so it cannot leak into others, and where `backdrop-filter` is unsupported it
degrades to flat translucency.

### Layout-bearing themes (Workbench)

Some themes imply more than colour and chrome. A theme may set a small,
fixed set of *layout presets* the editor already supports, declared in the
theme's definition and applied on connect:

- default view mode (Workbench opens in Split),
- status bar on/off (Workbench shows one),
- source line numbers on/off (Workbench shows them),
- toolbar placement (reserved for the deferred Studio theme).

These presets are *defaults*, not locks: the visitor can still switch mode,
toggle the status bar, and so on. They are the only behavioural surface a theme
may touch; anything beyond this list is out of scope (see Non-Goals).
Workbench's status bar shows only data the editor already has (mode, word count,
save state); synthetic fields from the mockup (cursor position, encoding) are
omitted unless they are cheap to source.

### The selector and persistence

A `wa-dropdown` (or `wa-select`) in the top toolbar lists the themes; the
colour scheme keeps its three-icon radio. Both axes persist in `localStorage`
(`editor-theme`, `editor-color-scheme`).

Precedence for the initial theme is: a valid stored `editor-theme`, else the
config default, else `paper`. The editor page emits the config default as the
initial `data-editor-theme` value; a tiny inline bootstrap script in the page
`<head>` overrides it from `localStorage` when a valid stored value exists, and
sets `wa-light`/`wa-dark` from the stored scheme, all before the body renders so
there is no flash. The stored theme is validated against the known set before
being applied; an unknown value falls back to `paper`. The custom element then
syncs its controls to the resolved values on connect.

The config default comes from a new RFC-0011 key, `editor_theme` (defaulting to
`paper`). It is a default only: a stored preference always wins, so the operator
sets the first-visit look without overriding anyone's choice.

### Initial themes

- **Paper** -- the current design, default, no attribute required.
- **Aurora** -- a calm frosted-glass theme derived from mockup J but toned down:
  a neutral, muted gradient (soft slate and haze, only a hint of colour) under
  frosted-glass surfaces, in both a light and a dark variant. Needs the
  structural layer for the gradient and blur.
- **Blueprint** -- mockup I: cyan-on-navy; tokens plus a grid background layer.
- **Herbarium** -- mockup M: sage/sepia on ruled paper; tokens plus ruled-line
  and margin-illustration layers.
- **Workbench** -- mockup B: an IDE look; dark and light token sets, a status-bar
  structural layer, and the Split/line-number layout presets.

Each ships light and dark variants. Studio (mockup C) is deferred to a later
round, after the bubble-toolbar/slash-menu spike, so it can ship as the real C
rather than a half-version.

## Alternatives Considered

- Lean entirely on Web Awesome's `wa-theme-*`/palette system: rejected as the
  primary lever, because the editor's identity lives in the hand-styled surface
  (gradient, glass, grid, chrome) that WA component theming does not reach. A WA
  palette per theme stays available as secondary control harmonisation.
- One CSS *class* per theme instead of an attribute: rejected; the axis is
  single-valued and an attribute avoids clashing with WA's `wa-theme-*` classes.
- A separate, lazily loaded stylesheet per theme: rejected for now; the themes
  are few and small, so one stylesheet is simpler. Revisit if themes proliferate.
- Pulling Studio's bubble toolbar and slash menu into theming: rejected; that is
  a genuine interaction redesign (the deferred Lit spike), far larger than a
  theme, and would couple a visual axis to a behavioural one.

## Security Impact

- CSS and client JS only; no server or protocol change beyond a read-only config
  key.
- The persisted theme is a non-sensitive preference. The pre-paint bootstrap and
  the config-supplied default must set `data-editor-theme` only from a validated
  allowlist of known theme names, never a raw stored or configured string, so a
  tampered `localStorage` value or config entry cannot inject an attribute
  payload.

## Reliability Impact

- An unknown, missing, or invalid stored or configured theme resolves to
  `paper`; the editor never renders unstyled.
- `backdrop-filter` and large gradients are GPU-costlier; unsupported
  `backdrop-filter` degrades to flat translucency. No effect on the server.
- The pre-paint script is small and synchronous; if it fails, the element's
  on-connect sync still applies the resolved theme (a brief flash at worst).

## Compatibility Impact

- Editor frontend plus one config key. Adds the `data-editor-theme` attribute,
  an inline bootstrap script, and a theme dropdown to the editor page
  (`TestApp.hs` `editorPage`), token blocks and structural rules in
  `markdown-editor.css`, the selection/persistence/preset logic in
  `markdown-editor-element.ts`, and an `editor_theme` key read via
  `MicroHttp.Config`.
- The existing colour-scheme `theme` attribute and its semantics are unchanged;
  the new axis is additive. Workbench's and Studio's presets reuse existing
  editor capabilities (mode, status bar, line numbers, toolbar placement).

## Testing and Quality Gates

- `make check` stays green (includes `editor-check`: TS typecheck, lint, format,
  and the editor unit tests).
- Behaviour tests, added once the interaction stabilises (per `AGENTS.md`):
  selecting a theme sets `data-editor-theme` on the root and persists across a
  reload; the colour-scheme control still works and is independent; an invalid
  stored theme falls back to Paper; the config default applies only with no
  stored preference; a layout-bearing theme applies its presets (e.g. Workbench
  opens in Split) without locking them.
- `MicroHttp.Config` test for the `editor_theme` default and override.
- No tests asserting specific colours, gradients, or other visual taste
  (`AGENTS.md`).

## Rollout Plan

1. Phase one: the mechanism and the first visual theme.
   - [ ] `data-editor-theme` axis, token contract, and the default `paper`
         mapping in `markdown-editor.css` (no visual change to the default).
   - [ ] Theme dropdown, `localStorage` persistence for both axes, the validated
         pre-paint bootstrap, and the `editor_theme` config default (fallback
         only). `make check` green.
   - [ ] Aurora theme (neutral, light and dark, plus its glass/gradient layer).
2. Phase two: the remaining visual-only themes.
   - [ ] Blueprint and Herbarium (tokens plus their structural layers).
   - [ ] Behaviour tests for selection, persistence, independence, fallback, and
         the config default.
3. Phase three: the layout-bearing theme.
   - [ ] Workbench (tokens, status-bar chrome, Split and line-number presets).
4. Phase four: document and decide deferrals.
   - [ ] ADR for the theming architecture; note in the editor design docs.
   - [ ] Record Studio as a future round (after the bubble/slash spike).

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing the
  affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

Resolved during review (2026-06-15):

- Selector UI is a dropdown.
- The bounded preset list (default mode, status bar, line numbers, toolbar
  placement) is accepted as-is.
- The colour scheme stays a client-only preference; only the theme gets a config
  default (`editor_theme`).
- Studio is deferred to a later round (after the bubble/slash spike); when it
  returns, its toolbar may sit below the workspace chrome if placing it inside
  proves awkward.

None outstanding.
