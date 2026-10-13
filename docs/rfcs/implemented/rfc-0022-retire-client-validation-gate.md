---
id: RFC-0022
name: Retire the client validation gate
status: Implemented
owners:
    - alistairbayley
created: 2026-06-20T23:40+12:00
updated: 2026-06-21T00:30+12:00
supersedes: []
superseded_by: null
---

<!-- Filename: rfc-0022-retire-client-validation-gate.md -->

# Retire the client validation gate

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-06-20 23:40 NZST |
| Started   | 2026-06-21 00:12 NZST |
| Completed | 2026-06-21 00:30 NZST |

## Summary

The editor runs two Markdown engines: `marked` (via `@tiptap/markdown`) drives
every surface a user sees; `remark` (the content-extension registry) survives in
production only as a validation gate whose rendered HTML is discarded. The gate
validates a third representation whose acceptance diverges from `marked`'s,
silently blocking valid documents (e.g. an empty list item makes the Markdown and
split views unreachable) and silently dropping rejected edits. This RFC retires
the runtime gate, deletes the dead Markdown-to-HTML render half, keeps the
`remark` parse pipeline as a test-only subset spec, and replaces the narrow
parse-error UI with a general client-side error boundary. The saved-page contract
becomes round-trip stability under offline trust (ADR-0051).

## Context

See ADR-0051 for the full decision and rationale, and `GLOSSARY.md` for the
**round-trip stability**, **Visual/Markdown/Split view**, and "no preview pane"
language. Key production facts established during design:

- `renderMarkdown` (`remark` parse + HTML render) is called only in
  `switchMode` and `updatePreviewFromMarkdown`; its HTML output is always
  discarded because `this.preview` is never assigned.
- On gate failure, `handleSourceInput`/`handleVisualInput` return before
  `dispatchMarkdownChange`, so the rejected content is shown but never saved.
- The "round-trip" golden tests exercise `documentToMarkdown(parseMarkdown(md))`
  -- the `remark` pipeline, the markdown<->model inverse pair -- not the real
  save pipeline (`marked` DOM -> `documentFromElements` -> `documentToMarkdown`).
- `remark` is still needed in the load path for badge/raw-HTML span offsets
  (`rawHtmlSpans`/`badgeSpans`) and as the serialiser's model.

## Goals

- The Visual, Markdown, and Split views switch on every loadable document.
- No edit is ever shown but silently not saved.
- One display engine in production (`marked`); `remark` parse/render carries no
  production runtime role.
- Unexpected client failures surface to the user instead of failing silently.

## Non-Goals

- Closing the `marked`-DOM -> `documentFromElements` test gap (stays manual,
  Chrome; recorded as residual risk in ADR-0051).
- Any server-side change: the raw-HTML save guard (ADR-0041) is untouched, and no
  server-side renderer is added (ADR-0019/ADR-0040 hold).
- Server-side error telemetry (deferred to RFC-0023).
- Reconciling `marked` vs `remark` vs MkDocs rendering of the same source.

## Proposal

Three independently shippable slices; `make check` green after each.

### Phase 1 -- Retire the runtime gate

- [x] Remove the `renderMarkdown` validation call from `switchMode`
      (`markdown-editor-element.ts`): switching becomes serialise -> set mode ->
      `renderMode`, with no representability check.
- [x] In `handleSourceInput`/`handleVisualInput`, stop gating on
      `updatePreview`; always `dispatchMarkdownChange` so edits are recorded.
- [x] Remove `updatePreview`/`updatePreviewFromMarkdown` and the always-null
      `preview` field.
- [x] Remove the parse-error UI: the `parseError` element, `showParseError`/
      `hideParseError`, the footer wiring for it, and the
      `.markdown-editor__error` CSS. Keep the save-error and upload notices.
- [x] Verify in Chrome (`preview_*`): the `noc-procedure-lnms-11.md` page
      switches to Markdown and Split; edits in each mode persist on save.

### Phase 2 -- Delete the Markdown-to-HTML render half

- [x] Delete `markdown-render.ts` (`renderMarkdown`).
- [x] Remove `renderDocument` and the `RenderContext` from
      `content-extension.ts`, and `renderBlock`/`renderInline`/`renderDocument`
      from the `ContentExtension` interface.
- [x] Remove the render seams from each extension (base, footnote, badge,
      admonition, collapsible, image, reference-link, raw-html, table, ...).
- [x] Delete the "X rendering" test blocks; keep every `parseMarkdown` +
      `documentToMarkdown` round-trip and DOM-serialisation test.
- [x] Remove dependencies `knip` now reports unused. Outcome: none. The
      `remark-rehype`/`rehype-stringify`/`remark-stringify` packages belong to
      `scripts/remark-ast-spike.mjs` (and are knip-ignored), not the render half,
      so no dependency changed.

### Phase 3 -- Global client error boundary (companion)

- [x] Add a top-level boundary in `<markdown-editor>`: `window` `error` and
      `unhandledrejection` listeners (scoped to editor-originated failures) plus
      the existing `initialise().catch`.
- [x] Surface a dismissible banner ("Something went wrong in the editor. Your
      last saved version is safe.") and `console.error` the underlying error.
      Deviation from the original plan: the banner is a **top-level** child, not a
      footer notice -- the footer is `display:none` in the read view, where a
      render-time crash is exactly the case that must surface. It is attached
      after the inline content is read (or on demand if a failure occurs first).
- [x] Tests: a thrown error in an editor code path shows the banner and does not
      wedge the editor.

## Alternatives Considered

- **Runtime self-check (marked-based round-trip):** rejected. It can only warn
  (the content is already in the DOM; you cannot refuse the author's typing) and
  doubles load/serialise work per edit for a signal it cannot act on.
- **Delete the `remark` parse pipeline entirely:** rejected. It is the only
  executable definition of the supported subset and the serialiser's
  inverse-check; cheap to keep as a test fixture (ADR-0051 decision 3).
- **Keep the gate and keep patching divergences:** rejected. Whack-a-mole; the
  gate validates the wrong artifact and fails invisibly.
- **Adopt Effect.ts for error handling:** rejected. Too large a paradigm for a
  two-runtime-dependency editor with a tiny error surface.

## Security Impact

- No new server surface. The server's raw-HTML rejection trust boundary
  (ADR-0041) is unchanged.
- The error banner must not leak document content or stack internals to the
  user-facing message; the detail goes to the console only.

## Reliability Impact

- Removes a silent show-vs-save divergence (edits rejected by the gate were
  never saved).
- Adds a general silent-failure backstop (the error boundary).
- Residual risk (ADR-0051): `marked` DOM -> `documentFromElements` remains
  manually verified in Chrome; this RFC does not change that.

## Compatibility Impact

- Internal only. The Markdown HTTP/storage contract is unchanged. The
  `ContentExtension` interface loses its render seams -- a source-level change to
  extensions, all in-repo.

## Testing and Quality Gates

- `make check` and `make editor-check` green after each phase.
- Retained golden round-trip and DOM-serialisation tests are the offline net.
- Chrome `preview_*` verification of view switching and edit persistence on a
  document that previously failed the gate.

## Rollout Plan

1. Phase 1 -- retire the runtime gate.
2. Phase 2 -- delete the render half.
3. Phase 3 -- global error boundary + banner.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or ADR-0051 does not cover, stop
  changing the affected scope before inventing a contract. Add the smallest
  missing decision to `## Open Questions` (or the owning ADR), with evidence,
  impact, options, and a recommendation, and continue only after explicit
  approval.

## Open Questions

Both resolved during implementation:

- Phase 3 scope of "editor-originated": resolved to **whole page** -- the editor
  is the page in the TestApp, so page-level `window` errors and rejections raise
  the banner (no bundle-filename filtering).
- Does any extension's `renderDocument` encode logic the serialiser also needs?
  Resolved **no**. The footnote `renderDocument` (numbering + collected list) was
  HTML-only; serialise-out is DOM/model-driven and independent. All render seams
  were removed with no serialiser impact (round-trip tests stayed green).
