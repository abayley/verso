---
id: RFC-0020
name: Reading Is The Default, Rendered Read-Only View
status: Draft
owners:
    - alistair
created: 2026-06-19
updated: 2026-06-19
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Reading Is The Default, Rendered Read-Only View

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-19 08:43 |
| Started   |                  |
| Completed |                  |

## Summary

Make reading a tree document the default: a plain `GET /documents/<path>.md`
renders the document read-only in the browser, instead of serving raw Markdown.
The read view *is* the editor shell with editing switched off -- the same visual
rendering, the same view switcher (visual / Markdown / split), width, theme, and
side panels -- but with the editing controls hidden and the content not editable,
so reading and editing look identical. `?edit` opens the editable shell (today's
behaviour); `?raw` serves the raw Markdown for tooling. Rendering stays
browser-owned (ADR-040); this amends ADR-045's "a `GET` serves the raw Markdown".

## Context

A tree page is reachable today as a plain `GET` (raw Markdown), `?edit` (the
editor), and other files served statically (ADR-045). Following a link to a page
shows raw Markdown source, which is poor for reading. The rendering capability
already exists in the editor -- its visual surface (Tiptap) and split preview
render the full content-extension subset -- and the owner wants the read view to
match the editor's rendering as closely as possible, to carry the same side
panels (the metadata/attachments panel today, RFC-0019; a navigation tree and a
table of contents later), and to keep the visual / Markdown / split view switcher
available while reading. The cleanest way to get parity and shared chrome is to
reuse the editor shell in a read-only mode rather than build a second renderer.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- A plain `GET /documents/<path>.md` renders the document read-only by default.
- The read view reuses the editor shell: same visual rendering (parity with
  `?edit`), same view switcher / width / theme / panels.
- In the read view the editing controls are hidden and the content is not
  editable; there is no save, autosave, or upload.
- `?edit` opens the editable shell (unchanged); `?raw` serves raw Markdown.
- No server-side Markdown rendering (ADR-040); no-JavaScript reading stays raw
  Markdown.
- Reuse the existing metadata/attachments panel; leave slots for the navigation
  tree and table-of-contents panels.

## Non-Goals

- Building the navigation-tree (LHS) or table-of-contents (RHS) panels -- each is
  its own follow-up RFC that slots into this shell.
- A server-side Markdown renderer or rendered-HTML caching.
- A separate lightweight reader bundle (the editor shell is reused; parity and
  shared panels outweigh payload).
- A rendered view for the flat single-document store (this is tree-mode reading).
- Live execution of the tree's raw HTML (it renders inert, ADR-048).

## Proposal

### Selectors on a tree document

`treeGet` resolves a Markdown path by selector: a plain `GET` serves the
**read-only rendered shell** (new default); `?edit` serves the **editable shell**
(today's editor); `?raw` serves the **raw Markdown** verbatim as `text/markdown`
(today's plain-`GET` behaviour, frontmatter included, moved behind the selector).
`POST` still saves. Non-Markdown files are served statically as before. The page
lives at the document's own URL in every case, so relative `assets/...` resolve
for free.

A **missing** page returns `404` for both a plain `GET` (read) and `?raw` -- you
cannot read or fetch a file that does not exist. Seeding a starter document stays
an **`?edit`-only** affordance, so "create by editing" is unchanged; read and raw
never seed.

### The read-only shell

The read view reuses the `markdown-editor` element via an opt-in `data-readonly`
attribute set by the server. **Its absence means editable** (the default), so the
flat store, `?edit`, and every current caller are unchanged; the server sets it
only on the default-`GET` read page and, in that case, also omits the surrounding
`hx-post` form -- read-only is enforced at the page level, not just hidden chrome.

The split is along the editor's own structure: the **top bar is presentation and
stays; the bottom bar is editing controls and goes**. When read-only:

- the content is not editable (Tiptap `editable: false`; the source view is
  read-only);
- the **bottom bar** (formatting/command toolbar with Save) and the floating
  editing affordances -- bubble toolbar, slash menu, table and link controls, and
  the upload path (file input plus drop/paste handlers) -- are hidden/disabled;
- the **top bar** stays in full: the view switcher (visual / Markdown / split),
  width, theme, and the document name, plus the side panels.

The view mode is not persisted (it defaults to visual), so reading opens in
**visual** -- the canonical rendered experience -- and switching to Markdown
(read-only source) or split is session-only. Because it is the same shell, the
read view matches the editor's output **per view**: reading in visual is exactly
editing in visual, just non-editable. (Making the visual and split renderers agree
with each other is a separate, pre-existing concern, out of scope.)

### Panels in read mode

The metadata/attachments panel (RFC-0019) renders in both modes. In read mode it
degrades to a read-only list: the attachment names and their open-file links
remain, while the mutating actions (Insert and drag-to-insert) are hidden/disabled
(append-on-upload is moot without uploads). The navigation tree and table of
contents are follow-up RFCs that mount into the same shell and behave read-only
here too.

### Moving between reading and editing

Read and edit are separate URLs, so each view carries a top-bar affordance to the
other: an "Edit" control in the read view (-> `?edit`) and a reciprocal
"View"/"Done" control in the edit view (-> plain `GET`). It is plain navigation
(an anchor), so it works without JavaScript; the exact widget and placement are
browser-first (AGENTS.md), not specified here.

### Raw access and no-JavaScript

`?raw` is the explicit raw-Markdown endpoint for tooling and diffs. With no
JavaScript, a plain `GET` degrades to the embedded raw Markdown (the shell's
fallback), so no-JavaScript reading is still raw Markdown -- consistent with
ADR-040.

### Decision record

This changes public behaviour (a plain `GET` renders instead of serving raw
Markdown) and is hard to reverse, so it is recorded as **ADR-050**, which amends
ADR-045's request model: `GET` reads (rendered), `?raw` is raw Markdown, `?edit`
edits, `POST` saves. The document id and URL scheme are otherwise unchanged.

## Alternatives Considered

- Additive `?view`, plain `GET` stays raw Markdown (this RFC's earlier draft):
  rejected by the owner -- reading should be the default, not opt-in.
- A separate lightweight `renderMarkdown` reader bundle: rejected -- it would not
  match the editor's rendering and could not host the view switcher or panels;
  parity and a shared shell were preferred over a smaller payload.
- `Accept`-based content negotiation for raw Markdown (render to `text/html`, raw
  to tooling): viable and link-transparent, but `?raw` is explicit and easier to
  reason about; negotiation stays a later option.
- A standalone read-only renderer component: rejected -- duplicates the shell;
  an `editable` flag on the existing element is less code and guarantees parity.
- Server-side rendering: rejected -- reintroduces the cross-language renderer
  ADR-040 removed.

## Security Impact

- Rendering stays browser-owned (ADR-040); the server gains only selector routing.
- The read view has no write path: no form, no autosave, no upload, and the
  panel's mutating actions are hidden/disabled.
- The trusted tree's raw HTML renders **inert** (ADR-048) -- shown, not executed.
- `?raw` and `?edit` resolve through the same path-safe `Static.resolveStaticPath`
  used today.

## Reliability Impact

- A plain `GET` with no JavaScript (or a render failure) degrades to the embedded
  raw Markdown rather than a blank page.
- `?edit` and `POST` save are behaviourally unchanged; the `editable` flag is the
  only fork.

## Compatibility Impact

- **Breaking (intended):** a plain `GET /documents/<path>.md` now returns the
  rendered shell, not raw `text/markdown`. Tooling and diffs must use `?raw`. This
  amends ADR-045 and is recorded as ADR-050.
- Flat mode is unchanged.
- No new build artifact: the read view reuses the editor bundle.

## Testing and Quality Gates

- `make check` and `make editor-check`.
- Server integration tests: a plain `GET` of an existing page returns the
  read-only shell (no `hx-post` form, `data-readonly` set, content embedded);
  `?edit` returns the editable shell with the form; `?raw` returns the verbatim
  file as `text/markdown` (frontmatter included); `POST` still saves; a missing
  page returns `404` for both a plain `GET` and `?raw`, while `?edit` on a missing
  page still seeds.
- Editor data-seam tests (vitest): with `data-readonly`, the content is not
  editable and the bottom bar / bubble / slash menu / table / link / upload / Save
  are absent, while the view switcher, width, theme, and the attachments list
  remain; the panel's insert/drag actions are disabled.
- Browser-first (preview): rendering parity between read and edit per view, view
  switching (visual / Markdown / split) while reading, relative-asset resolution,
  `?raw`, and the read/edit navigation affordance.

## Rollout Plan

1. Editor element: a `data-readonly` mode -- disable content editing, hide the
   bottom bar and floating editing affordances, keep the top bar (view switcher /
   width / theme / name) and panels; vitest.
2. Server: a plain `GET` serves the read-only shell (no form), `?edit` the
   editable shell, `?raw` the verbatim Markdown, with `404` on a missing
   read/raw target; integration tests. (ADR-050 already recorded.)
3. Read-mode panel behaviour (hide mutating actions) and the read/edit navigation
   affordance; browser-verify parity, view switching, assets, and `?raw`.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do
  not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- The navigation-tree (LHS) and table-of-contents (RHS) panels are out of scope
  here; this RFC only leaves slots for them in the shared shell.
- Read and edit stay separate URLs (`GET` vs `?edit`), which keeps deep-linking
  and the no-JavaScript form story intact; a single-URL client toggle is not
  proposed.
- Any editor-only load-time fix-ups must be matched so read and edit render
  identically; sharing the shell makes this mostly automatic, but it needs a check.
