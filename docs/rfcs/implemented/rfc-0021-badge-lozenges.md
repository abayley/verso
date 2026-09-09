---
id: RFC-0021
name: Badge Lozenges As A Content Extension
status: Implemented
owners:
    - alistair
created: 2026-06-20
updated: 2026-06-20
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Badge Lozenges As A Content Extension

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-20 13:01 |
| Started   | 2026-06-20 14:30 |
| Completed | 2026-06-20 16:15 |

## Summary

Recognise the documentation tree's badge lozenges -- an inline code span with a
`{.badge.<colour>}` attribute list, e.g. `` `TODO`{.badge.yellow} `` -- as a
first-class inline construct in the editor, rendered as a coloured pill rather
than shown as literal backticks-and-braces, and round-tripped back to the exact
source. It is a new content extension (RFC-0017): one module plus a
`registerExtension` call, with the parse/render/serialise/DOM seams the mechanism
already defines, registered (like `raw-html`) only in tree mode.

## Context

The corpus uses these badges heavily: ~560 files, with `{.badge.<colour>}` where
the colour is one of yellow, red, green, orange, blue, purple, gray, black (every
occurrence is exactly two classes, `badge` then a colour). MkDocs' `attr_list`
attaches the classes to the inline code, so the site renders
`` `TODO`{.badge.yellow} `` as `<code class="badge yellow">TODO</code>`, styled as
a pill (background, border, non-monospace font) by the theme's `custom.css`.

Today the editor has no badge support: remark parses the code span and leaves the
`{.badge.yellow}` as literal text, and the visual editor (marked) does the same,
so a badge shows as `` `TODO`{.badge.yellow} `` verbatim -- ugly to read and easy
to corrupt on edit. Badges are not raw HTML, so they do not go through the
`raw-html` path; they are a structured inline construct that deserves its own
extension.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- Parse `` `text`{.badge.<colour>} `` into a badge inline node (text + colour).
- Render it as a coloured pill (matching the site's `code.badge.<colour>`).
- Serialise it back to the exact `` `text`{.badge.<colour>} `` source.
- Work in both render paths: the preview/read view (remark) and the visual editor
  (marked), and survive a visual-editor round-trip.
- Registered only in the trusted tree mode, like `raw-html`.

## Non-Goals

- Arbitrary `attr_list` support (other classes, ids, key=value attributes) -- only
  the `badge` + single-colour shape the corpus uses.
- Raw HTML or live HTML execution (the badge is a controlled, escaped pill).
- A flat-mode feature (badges are a tree-document construct).

## Decisions

Resolved with the owner (2026-06-20):

- **Editable text, badge as styling.** The badge is a Tiptap **mark** on the text,
  not an atom, so the text stays editable and the colour is a styling applied over
  it.
- **Any named colour.** The colour is not restricted to a fixed set; whatever
  colour class is written is accepted and used as the badge **background colour**
  (the eight known names are just the common ones offered in the picker). An
  unknown colour still renders (its name as the background) and round-trips.
- **Semantic element.** Render a `<span class="badge">` carrying the colour
  (rather than reusing `<code>`); the editor styles it. The round-trip Markdown is
  unchanged (`attr_list` on the inline code).
- **Authoring control with a colour picker.** Add a command-bar control that wraps
  the selection in a badge and offers a short list of common colours.
- **Tolerant parsing.** Accept both `{.badge.<colour>}` and the spaced
  `{ .badge .colour }` forms.

Grilled (2026-06-20), the contracts these imply:

- **Strict recogniser.** A badge is an inline code span *immediately* followed
  (no space, `attr_list` semantics) by an attribute list that is *exactly* the
  `badge` class and one colour class (`[A-Za-z][\w-]*`). Every other shape -- a space
  before the brace, a missing colour, a colour-only list, extra classes, ids,
  `key=value` -- stays literal text. The corpus is uniform (~560 files, all the
  strict form), so this loses nothing.
- **Literal content; mark excludes other inline marks.** The badge wraps literal
  text (it is a code span), so no bold/italic/link can sit inside it; the model
  cannot drift from what `` `…` `` can encode. Serialise widens the backtick fence
  if the text contains backticks (CommonMark).
- **Colour is injection-safe by construction.** The validated `[A-Za-z][\w-]*`
  token is placed in an inline `background-color`; no CSS metacharacter can survive
  the recogniser. An unknown colour name the browser rejects falls back to a
  neutral pill (the `.badge` class).
- **Canonicalising serialise.** Output is always the strict
  `` `text`{.badge.<colour>} `` form; a tolerant spaced variant normalises to it.
- **No ADR.** This is a routine RFC-0017 content-extension instance (like image
  and raw-html), registered in tree mode; it introduces no new architectural or
  trust-boundary decision. RFC-0021 is the record.

## Proposal

### A `badge` content extension (RFC-0017)

Add one module registering a `badge` extension with the standard seams:

- **Parse (remark, preview/read path):** a remark plugin (or an `inlineFromMdast`
  that pairs an `inlineCode` node with an immediately-following
  `{.badge.<colour>}` text node) produces a `badge` inline node carrying the code
  text and the colour.
- **Parse (marked, visual editor):** pre-extract `` `text`{.badge.<colour>} ``
  spans before marked (the established pattern for footnotes, reference links,
  raw HTML), then re-apply them after load as a `badge` **mark** (with a `colour`
  attribute) on the code text -- keeping the text editable.
- **Render:** `<span class="badge" data-badge-colour="<colour>">text</span>` with
  the colour set as the background (the text stays escaped/inert content of the
  span); the editor styles `.badge` as a pill (padding, radius, readable
  foreground) and applies the colour as the background.
- **DOM serialise-in:** a `span.badge` element becomes a badge inline (text +
  colour read from `data-badge-colour`).
- **Serialise-out:** `` `text`{.badge.<colour>} ``, byte-for-byte.

### Authoring

A command-bar control wraps the current selection in a badge and offers a short
colour picker (the common colours: yellow, red, green, orange, blue, purple, gray,
black); choosing a colour applies/updates the badge mark. (Parsing accepts any
colour name even though the picker lists only the common ones.)

## Alternatives Considered

- Treat badges as raw HTML: rejected -- the source is Markdown (`attr_list`), not
  HTML; preserving it as raw HTML would not render a pill and would not round-trip
  to the Markdown form.
- A general `attr_list` extension: rejected for now -- far larger surface than the
  single `badge` shape the corpus uses; revisit only if other attribute uses
  appear.
- Render as a `<span>` rather than `<code>`: deferred to grilling -- the site uses
  `<code>`, so matching it keeps the editor and the built site consistent.

## Security Impact

- No raw HTML or execution surface: the badge renders an escaped, inert pill with
  a fixed class shape; the text is escaped like any inline content (consistent
  with ADR-0040/0041).
- Registered only in tree mode (trusted first-party content), like `raw-html`.

## Reliability Impact

- An unrecognised or malformed `{.badge...}` falls back to today's behaviour
  (literal text), so nothing breaks; the construct is additive.
- Round-trip is verbatim, so a save never rewrites a badge it did not change.

## Compatibility Impact

- Flat mode is unchanged (extension not registered).
- No new server behaviour; this is editor-side (browser-owned rendering, ADR-0040).

## Testing and Quality Gates

- `make editor-check`.
- Editor data-seam tests (vitest): parse `` `text`{.badge.<colour>} `` to a badge
  node; render to `span.badge` with the colour as `data-badge-colour` and
  `background-color`; DOM serialise-in from `span.badge`; serialise-out
  canonical; round-trip for each common colour and an arbitrary colour; a bare
  code span and every non-conforming attr-list shape (space before brace, missing
  colour, extra classes, id/attr) stay literal; backtick-in-text widens the fence.
- Browser-first (preview): a badge renders as a pill in the read view and the
  visual editor, and round-trips through a visual edit.

## Rollout Plan

1. The `badge` extension module (parse/render/serialise/DOM seams) and its
   registration in tree mode, with the remark path and vitest.
2. The visual-editor path: pre-extraction/tokenizer plus a Tiptap `badge` node;
   round-trip tests; browser-verified.
3. Pill styling for the eight colours (and the fallback), browser-first.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do
  not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- **Foreground/contrast:** the colour sets the background; the readable text
  colour over an arbitrary named background is decided browser-first (a fixed dark
  or light foreground, or a per-colour rule for the common eight). Not a blocker.
- **Multiple badges adjacent / nested marks:** confirm the mark composes with
  other inline marks (e.g. a link inside a badge) during implementation.
