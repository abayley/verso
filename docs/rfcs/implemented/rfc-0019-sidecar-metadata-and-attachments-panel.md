---
id: RFC-0019
name: Sidecar Metadata Maintenance and the Attachments Panel
status: Implemented
owners:
    - alistair
created: 2026-06-18
updated: 2026-06-18
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Sidecar Metadata Maintenance and the Attachments Panel

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-18 20:34 |
| Started   | 2026-06-18 20:34 |
| Completed | 2026-06-18 21:10 |

## Summary

Two features for the document-tree editing mode (ADR-0045). First, keep a page's
**sidecar metadata** in step with its assets: an upload records the new asset in
the page's `attachments.yaml` or `images.yaml`, and a save updates an inline
image's `short_title` to follow the body image's alt text. All writes are
minimal-byte edits that never reserialise the legacy files (ADR-0049). Second, a
**metadata panel** in the editor that lists the page's attachments -- including
ones not linked from the body -- and lets the author drag one into the document
as a link. The panel is the first of three planned chrome panels (a navigation
tree and a table of contents follow later).

## Context

The new documentation layout records every asset in a per-page meta directory
`<dir>/meta/<base>.meta/` containing `attachments.yaml`, `images.yaml`, and
`meta.yaml`. Today a tree upload (ADR-0046) writes the asset file into the page's
peer `assets/` but records nothing in this metadata, so the layout's index of a
page's assets goes stale on every upload. The corpus also holds attachments that
no page body links -- the author still needs to see them associated with the
page and be able to link them. The meta files were produced by a legacy CMS
export and carry fields and formatting we must not disturb, which constrains how
we may write them (ADR-0049).

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- Record every tree upload in the page's `attachments.yaml` or `images.yaml`.
- Keep an inline image's `short_title` in step with its body alt text.
- Surface the page's attachments (linked and unlinked) in a metadata panel.
- Let the author insert an attachment link by dragging it into the document.
- Touch only the bytes we own in the legacy meta files (ADR-0049).

## Non-Goals

- Touching `meta.yaml` (created-by, history, owner) -- a later panel concern.
- Reproducing the legacy `id`/`path` attachment fields for new uploads.
- Syncing an attachment's `name` from body link text (attachments are
  append-only).
- Deleting or renaming assets or metadata entries from the panel.
- A linked/unlinked badge on panel rows.
- The navigation-tree and table-of-contents panels.
- Concurrency or locking (single-user local tool).

## Proposal

### Meta directory and the YAML edit module

A new server module (`MicroHttp.DocumentMeta`) owns the meta directory and the
two minimal-byte edits. The meta directory for a page `<dir>/<base>.md` is
`<dir>/meta/<base>.meta/`; `index.md` yields `meta/index.meta/`. The module
provides: derive the meta directory from a document path; append an entry to a
target file (creating the directory and an `[]`-seeded file on demand,
deduplicating by `local_path`); surgically replace a `short_title` value within a
matched `local_path` block; and read the attachment entries (`name`,
`local_path`) for the panel.

### Upload records the asset

`treeUpload`, after `storeAsset` succeeds, classifies the stored name with the
existing `inlineImageExtension` and appends an entry to the target file:

- `attachments.yaml`: `name` (original filename, single-quoted), `local_path`
  (`assets/<stored-name>`, unencoded), `extension`, `external: false`. No
  `id`/`path`.
- `images.yaml`: `local_path`, `short_title` (filename at creation),
  `description: ''`.

Idempotent: an identical re-upload reuses the stored name (dedup in
`storeAsset`), so `local_path` is already present and nothing is appended.

### Save updates image short_title

On save the editor sends a `[{local_path, short_title}]` payload (an extra form
field on the existing `POST /documents/<path>.md`), computed from its document
model as alt text else filename. `treeSave`, after writing the `.md`, surgically
replaces the `short_title:` value within each matched `local_path` block in
`images.yaml`. Update-only (never creates entries), and writes nothing when the
value is unchanged. No-JS form saves carry no payload, so this is a JS-editor
enhancement (ADR-0039).

### Metadata panel

The server embeds the page's attachment list (name + `local_path`) into the
editor page on load. The editor renders a right-hand collapsible metadata panel
listing each attachment as a link to its page-relative `assets/...`. On a
successful non-image upload the editor appends the new attachment to the panel
client-side (using the upload response and the same `isInlineImage` boundary), so
the list stays live without a re-fetch. Dragging an attachment row into the
document inserts `[name](assets/<...>)` at the drop point; a click inserts at the
cursor as a fallback.

## Alternatives Considered

- Parse-and-reserialise the meta files: rejected (ADR-0049) -- rewrites untouched
  legacy entries in our style, losing `id`/`path`/ordering/quoting.
- Reproduce or synthesise `id`/`path` for new uploads: rejected -- no current
  consumer reads them, and a fabricated value is worse than an absent one.
- Server-side alt-sync by parsing the Markdown body: rejected -- crosses the
  ADR-0040 boundary (Markdown understanding is browser-owned); the editor already
  has the parsed model.
- A separate `?meta` JSON endpoint for the panel: deferred -- embed-on-load plus
  client-side append keeps the list live without a second route; revisit when
  history/created-by need lazy refresh.
- Syncing attachment `name` from body link text: rejected -- link text is
  contextual prose, `name` is the canonical filename, and unlinked attachments
  have no link text.

## Security Impact

- Writes stay within the page's meta directory and peer `assets/`, both derived
  through `Static.resolveStaticPath` (path-safe). No new path input.
- Tree mode is the trusted, first-party context (ADR-0048); the panel renders
  attachment names and page-relative hrefs as text/attributes (escaped), with no
  raw-HTML execution surface.
- The save payload only sets `short_title` values keyed by an existing
  `local_path`; an unmatched `local_path` is a no-op (no entry creation, no path
  write).

## Reliability Impact

- An upload that stores the asset but fails the metadata append leaves the asset
  on disk and unrecorded; a later identical re-upload heals the entry (dedup by
  `local_path`). The asset write remains the primary effect.
- Surgical edits are confined to located blocks; a meta file that does not match
  the expected shape is left untouched rather than rewritten.
- On-demand creation seeds a missing target file from `[]` before the first
  append.

## Compatibility Impact

- Flat mode (ADR-0014/0042) is unchanged: no meta directory, no panel.
- New attachment entries omit `id`/`path`; any future consumer of those fields
  must tolerate their absence (none exists today).
- The save gains an optional payload field; absent it (no-JS), the save behaves
  exactly as before.

## Testing and Quality Gates

- `make check` and `make editor-check`.
- Server unit tests (hspec) for `MicroHttp.DocumentMeta`: meta-directory
  derivation (nested and `index.md`); append to `[]`, append to a populated
  file, dedup by `local_path`, on-demand directory/file creation; surgical
  `short_title` replacement (matched, unmatched skip, unchanged no-op);
  attachment-entry read.
- Server integration tests: `?asset` upload appends the correct entry to the
  correct file by extension; a save with a `short_title` payload updates
  `images.yaml`; legacy entries and `meta.yaml` are byte-unchanged.
- Editor data-seam tests (vitest): the alt-else-filename `short_title`
  computation and the `[{local_path, short_title}]` payload builder.
- Browser-first (preview) for the panel, drag-and-drop insertion, and live
  append-on-upload; add an interaction-contract test once the drag insertion
  stabilises (per AGENTS.md).

## Rollout Plan

1. `MicroHttp.DocumentMeta`: meta-directory derivation and the YAML edits, with
   unit tests (TDD). No wiring yet.
2. Wire `treeUpload` to append the upload entry; integration tests.
3. Editor sends the `short_title` payload on save; wire `treeSave` to apply the
   surgical update; tests across the seam.
4. Metadata panel: server embed, sidebar UI, client-side append-on-upload, and
   drag-and-drop insertion; browser-verified.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do
  not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- Keeping `short_title` in step when an inline image is removed from the body, or
  its alt cleared, is update-only here (the entry stays). Whether a removed image
  should drop or blank its entry is deferred to the broader metadata work.
- The drag-and-drop data format and drop-target affordance are browser-first and
  will be settled against the running editor, not specified here.
