---
id: RFC-0001
name: Editor Progressive Enhancement
status: Draft
owners:
    - alistair
created: 2026-06-10
updated: 2026-06-10
supersedes: []
superseded_by: null
---

# Editor Progressive Enhancement

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-10       |
| Started   |                  |
| Completed |                  |

## Summary

Make `GET /documents/:id/edit` a fully functional server-rendered Markdown
form that works without JavaScript, and upgrade it in place to the rich
`<markdown-editor>` experience when JavaScript is available. The custom
element becomes a form-associated custom element through `ElementInternals`,
adopts the server-rendered textarea as its initial content, and stops
fetching the document separately. The hidden `markdown` input is removed.

## Context

The current edit page is an empty shell: the page renders an htmx form, the
element fetches the document through its `src` attribute, and the Markdown
value reaches the server through a hidden input populated during the htmx
`configRequest` event. A browser without JavaScript gets a blank, unusable
page.

The project direction discussion concluded that MicroHttp should stay a
reasonably general-purpose server for server-rendered htmx applications, with
the rich editor as an island of interactivity rather than the template for
application architecture. Progressive enhancement reconciles the two: the
server renders a meaningful, working page for every client, and capable
browsers upgrade it.

ADR-019 is unchanged by this design. A textarea of raw Markdown keeps the
server contract as Markdown text; the server still performs no Markdown
parsing or rendering beyond the existing save validation.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Editing and saving a document works with JavaScript disabled, through a raw
  Markdown textarea and an ordinary form post.
- The enhanced editor keeps all current behaviour: view modes, autosave, save
  states and notices, validation feedback, keyboard shortcuts.
- The element participates in form submission natively through
  `ElementInternals`, with no hidden input and no document fetch on the edit
  page.
- TestApp handlers answer both full-page form posts and htmx posts from one
  route.

## Non-Goals

- No server-side Markdown rendering (ADR-019 stands).
- No templating engine (ADR-022 defers templates).
- No visual design investment in the fallback page beyond legibility.
- No change to the `GET /documents/:id` raw `text/markdown` contract.
- No offline or conflict-resolution behaviour.

## Proposal

Server changes in `MicroHttp.TestApp`:

- `GET /documents/:id/edit` renders a form posting to `POST /documents/:id`
  that contains `<markdown-editor>` wrapping a
  `<textarea name="markdown">` holding the current document text, escaped by
  the HTML combinators. The page is a complete, usable editing page without
  any script.
- `POST /documents/:id` branches on the `hx-request` header (request header
  names are already normalised to lower case at parse time). htmx requests
  keep the current behaviour: validation, save, and a status fragment with
  `hx-swap="none"`. Non-htmx requests follow post-redirect-get: a successful
  save responds `303 See Other` back to the edit page; a validation failure
  re-renders the edit page with the error message and the submitted Markdown
  preserved in the textarea.

Browser changes in `src/TestApp/Editor/`:

- `MarkdownEditorElement` declares `static formAssociated = true` and
  attaches `ElementInternals`. On upgrade it reads the wrapped textarea's
  value as the initial Markdown, disables the textarea as a submitting
  control, and keeps the form value current through
  `internals.setFormValue(...)` as the document changes.
- The edit page stops using the `src` fetch. The `src` attribute remains
  supported for embedding contexts without a wrapped textarea, but the
  wrapped textarea takes precedence when present.
- The hidden `#markdown-field` input and the `configRequest` value-copying
  hook are removed once the form value flows through `ElementInternals`.
- The autosave contract is unchanged: the element dispatches
  `editor:changed` and htmx triggers the delayed form submission.

## Alternatives Considered

- Keep the hidden input and `src` fetch (status quo): no fallback for
  script-less browsers, an avoidable fetch round trip, and custom plumbing
  duplicating what the platform now provides.
- Render the rich editor markup server-side: contradicts ADR-019 and pulls
  editor logic into the server.
- A separate raw-editing route (for example `?raw=1`): two pages to keep in
  sync; enhancement-in-place avoids the drift.

## Security Impact

- Textarea content is escaped by the existing `Html.text` combinator path;
  this must be covered by a unit test with hostile document content.
- Validation and persistence are identical for both submission modes; no new
  trust boundary is introduced.
- The redirect target after a non-htmx save is fixed server-side, not derived
  from request input.

## Reliability Impact

- The no-JavaScript path has no autosave; explicit submit only. Acceptable
  for a fallback.
- Removing the initial document fetch removes a failure mode; the current
  fetch error is only reported to the console.
- Enhanced-mode save failure behaviour (Retry plus notice) is unchanged.

## Compatibility Impact

- Enhanced mode requires `ElementInternals` (baseline in evergreen browsers);
  older browsers fall back to the textarea page by design.
- Removing `#markdown-field` breaks any test or script that references it;
  the browser smoke script must be updated in the same phase.
- `happy-dom` support for `ElementInternals.setFormValue` decides whether
  form-value tests are unit tests or smoke assertions (open question).

## Testing and Quality Gates

- `make check`
- `make test-editor-browser`, extended with a JavaScript-disabled pass.

Test cases, simplest to most complex:

1. Given an edit request, when routing, then the page contains a form posting
   to the document and a textarea named `markdown` holding the escaped
   document content.
2. Given a non-htmx valid post, when saving, then the response is `303 See
   Other` back to the edit page and the Markdown is persisted.
3. Given a non-htmx invalid post, when validating, then the edit page is
   re-rendered with the validation message and the submitted Markdown
   preserved in the textarea.
4. Given an htmx post, when saving, then the existing fragment behaviour is
   unchanged.
5. Given an element wrapping a textarea, when initialised, then the editor
   adopts the textarea content and the textarea no longer submits a value.
6. Given an edited document, when the form value is read, then the
   `ElementInternals` form value is the current Markdown.
7. Given JavaScript disabled in the browser smoke run, when the textarea is
   edited and submitted, then the saved document round-trips through the
   redirect.
8. Given JavaScript enabled in the browser smoke run, then existing flows
   pass without the hidden `markdown` field.

## Rollout Plan

1. Phase one: server-rendered fallback form and dual-mode post handling
   (test cases 1 to 4).
   - [ ] Render the textarea form from `editorPage` with document content.
   - [ ] Branch `POST /documents/:id` on the `hx-request` header.
   - [ ] Post-redirect-get and validation re-render for non-htmx posts.
2. Phase two: element adoption and form participation (test cases 5, 6, 8).
   - [ ] Adopt wrapped textarea content as initial Markdown.
   - [ ] Add `ElementInternals` form participation and keep the value
         current.
   - [ ] Verify htmx submission carries the element's form value.
3. Phase three: remove legacy plumbing and extend smoke coverage (test case
   7).
   - [ ] Remove the hidden input and the `configRequest` value copy.
   - [ ] Stop using `src` on the edit page; decide the document-name source.
   - [ ] Add the JavaScript-disabled smoke pass.
   - [ ] Flip RFC status and record the outcome in the spike document.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts
  do not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- Does `happy-dom` implement `ElementInternals.setFormValue` well enough for
  unit-level form-value tests, or does that assertion belong in the browser
  smoke script?
- Does htmx 2 parameter collection include form-associated custom element
  values built from `FormData`? Verify early in phase two; the fallback is a
  `formdata` event listener on the form.
- Where should the displayed document name derive from once the edit page
  stops using `src`: the form action, or an explicit attribute?
- Should the adopted textarea stay in the DOM for assistive technology, or
  be removed after upgrade?
