---
id: RFC-0025
name: Editor load-rendering fixes (fenced code in lists; native-details collapsibles)
status: Draft
owners:
    - alistairbayley
created: 2026-06-21T18:53+12:00
updated: 2026-06-21T18:53+12:00
supersedes: []
superseded_by: null
---

<!-- Filename: rfc-0025-editor-load-rendering-fixes.md -->

# Editor load-rendering fixes

| Stage     | Timestamp          |
|-----------|--------------------|
| Authored  | 2026-06-21 18:53   |
| Started   |                    |
| Completed |                    |

## Summary

Two independent editor-load fixes found while reviewing real corpus pages.

- **A. Fenced code in lists.** A fenced code block inside a list item whose
  content contains a blank line is mangled on load: everything after the first
  blank line escapes the fence and is parsed as Markdown. Fix: pre-extract every
  fenced code block before the visual editor's Markdown loader, restoring each as
  a code-block node after load.
- **B. Native-details collapsibles.** Render collapsibles as semantic
  `<details>`/`<summary>` instead of a `<div>` with a custom toggle (ADR-054).

## Context

### A. Fenced code in lists

The visual/read editor loads Markdown through `@tiptap/markdown` (which uses
`marked`). On a page with an ordered list whose items contain multi-line
fenced code (e.g. Aruba switch boot output, with blank lines), the code block
truncates to everything before the first blank line and the rest becomes list
items and paragraphs. The same content is correct in `?raw` and under remark.

Diagnosis (important, to stop anyone "fixing marked"): **`marked` is not at
fault.** `marked.lexer` tokenises the fence-in-list correctly -- the `code`
token holds the full content. The truncation is in **`@tiptap/markdown`'s**
conversion of a `code` token nested in a list item to ProseMirror. So the fix
must keep fence *content* out of that converter, not change `marked`.

### B. Collapsibles as `<details>`

See ADR-054. RFC-0017's `<div>` is incidental (it avoided the paid Tiptap
`Details` Pro extension); the `???` source syntax and the raw-HTML ban are
unchanged. `<details>`/`<summary>` is the semantic element and is accessible by
default.

## Goals

- Fenced code inside lists (and inside collapsibles) loads and round-trips
  verbatim, blank lines and indentation preserved.
- Collapsibles are semantic, accessible `<details>` with the open state still in
  the document model and round-tripping to `???`/`???+`.
- No change to the Markdown source contract or the raw-HTML ban.

## Non-Goals

- Changing `marked` or replacing `@tiptap/markdown`.
- Authoring raw `<details>` or raw fenced HTML as Markdown input (still banned).
- Tiptap's paid `Details` Pro extension.

## Proposal

### Part A -- pre-extract fenced code blocks

Mirror the existing block raw-HTML sentinel pattern in
`TiptapVisualEditor` (footnotes, references, raw HTML, badges are already
pre-extracted before `setContent`).

1. **Extract first.** Before any other pre-extraction, scan the Markdown for
   fenced code blocks (``` or ~~~, with language and indentation), replace each
   whole fence with a one-line sentinel paragraph at the fence's opening indent,
   and record `{ language, content, indent }`. Doing this first protects fence
   content from the other extractors (footnote/badge/raw-HTML syntax inside a
   fence is no longer mis-extracted -- an incidental correctness gain).
2. **Load.** `@tiptap/markdown` parses the sentinel as an ordinary paragraph,
   which it places correctly inside the list item (the bug is specific to code
   tokens, not paragraphs), so the position is preserved.
3. **Restore.** After `setContent`, find each sentinel paragraph and replace it
   with a `codeBlock` node carrying the verbatim content (de-indented by the
   fence's opening indent) and language -- as `loadRawHtml` swaps sentinel
   paragraphs for raw-HTML block nodes today.
4. **Collapsible body re-parse.** `collapsibleNode` re-parses the body via the
   same `@tiptap/markdown` parse, so it has the same bug; the pre-extract/restore
   wraps that path too.
5. **Round-trip.** The restored `codeBlock` serialises back to a fence via the
   existing serialise seam; verify content with blank lines and indentation
   round-trips byte-for-byte.

### Part B -- render collapsibles as `<details>` (ADR-054)

- `Collapsible` node `renderHTML` and node view emit
  `<details><summary contenteditable="false">title</summary><div
  class="markdown-collapsible-body">0</div></details>`.
- The node view intercepts the `<summary>` toggle and routes it through a
  transaction that flips the `open` attribute (keeping it in the model, undoable);
  the `<details open>` attribute reflects the model.
- `parseHTML` and the DOM-serialise seam read `<details.markdown-collapsible>`.
- CSS: drop the custom `data-open` body-hide and `::before` arrow in favour of
  the native disclosure marker (style it to taste); keep the callout chrome.

## Alternatives Considered

- **Patch or upgrade `@tiptap/markdown` (Part A):** rejected -- depends on its
  internal handler API being invoked for the nested case (uncertain) and is
  fragile across upgrades; pre-extraction is deterministic and under our control.
  An upgrade was considered as a cheaper escape if it cleanly fixed the bug, but
  the diagnosis is specific and unconfirmed upstream.
- **Pre-extract only fences inside lists (Part A):** rejected -- detecting "in a
  list" is more complex than extracting all fences uniformly, and uniform
  extraction also protects fence content from the other extractors.
- **Tiptap `Details` Pro extension (Part B):** rejected -- paid dependency
  (RFC-0017).
- **Keep the `<div>` (Part B):** rejected -- loses native accessibility for no
  benefit; the `<div>` was never a principled choice.

## Security Impact

- No change to the raw-HTML ban: the editor renders `<details>` and code blocks
  but still never accepts raw HTML as Markdown input (ADR-040/041).

## Reliability Impact

- Part A removes a silent content-loss bug (fence content escaping) -- a
  round-trip-stability fix (ADR-051): a load that drops content then saves would
  lose it. Golden round-trip tests guard it.

## Compatibility Impact

- Internal. The collapsible DOM contract changes `<div>` -> `<details>` (parse and
  serialise move together). The Markdown HTTP/storage contract is unchanged.

## Testing and Quality Gates

- `make check` / `make editor-check`.
- Part A: tests for a fence in a list item with blank-line content (load shows
  one intact code block; round-trip is byte-identical), including inside a
  collapsible, and fences with `~~~`/indentation.
- Part B: tests for `<details>`/`<summary>` rendering, toggle routed through the
  model (open round-trips to `???`/`???+`), and DOM-serialise back to the model.

## Rollout Plan

1. Part A: fenced-code pre-extraction + restore (and the collapsible body path).
2. Part B: collapsible `<details>` rendering, toggle, parse/serialise, CSS.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or ADR-054 does not cover, stop,
  add the smallest missing decision to `## Open Questions` (or the owning ADR),
  with evidence, impact, options, and a recommendation, and continue only after
  explicit approval.

## Open Questions

- None outstanding; resolved during the RFC-0025 design grilling.
