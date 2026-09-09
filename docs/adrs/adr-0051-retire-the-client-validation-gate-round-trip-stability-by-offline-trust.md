---
id: ADR-0051
name: Retire The Client Validation Gate; Round-Trip Stability By Offline Trust
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0051: Retire The Client Validation Gate; Round-Trip Stability By Offline Trust

## Context

The editor runs two Markdown engines. `marked` (via `@tiptap/markdown`)
is the display and editing engine for every surface a user sees -- the read
view, the visual view, and the split view's right pane. `remark` (the
content-extension registry) was retained by ADR-0020 as "the reference parser and
validation fixture while Tiptap Markdown support settles", and ADR-0040/ADR-0041
kept a client save-time check that documents stay "within the editor's
round-trippable subset". In production that `remark` path survives only as a
validation gate: `renderMarkdown` is called in `switchMode` and
`updatePreviewFromMarkdown`, and its HTML output is discarded (the `preview`
slot it targets is never assigned -- there is no rendered-preview pane). The gate
therefore validates a third representation (`remark` mdast) whose acceptance
diverges from `marked`'s. When `remark` is stricter, it blocks documents
`marked` renders fine -- invisibly, because the parse-error banner lives in the
read view's hidden footer: an empty list item (`listItem:empty`) made the
Markdown and split views silently unreachable, and a rejected edit is shown on
screen but never recorded for save (the early return skips
`dispatchMarkdownChange`, so `setFormValue`/`markDirty` never fire).
Tiptap/`marked` has since become the de facto engine across read, visual, split,
and every shipped extension; the "while Tiptap settles" condition of ADR-0020 has
elapsed.

## Decision

(1) Name the saved-page contract **round-trip (reopen) stability**:
reopening a saved page shows the author what they last saw, measured through the
real `marked` + serialiser pipeline, not representability in any external grammar
(`CONTEXT.md`). (2) Retire the runtime validation gate -- no `remark` validation
in `switchMode` or on edit -- and remove the parse-error UI and the always-null
`preview` slot. Enforcement is **offline trust**: the per-extension golden
round-trip tests ADR-0041 already designated as the correctness net. (3) Keep the
`remark` parse pipeline **test-only**, as the executable definition of the
supported subset and the serialiser's inverse-check (`parseMarkdown` then
`documentToMarkdown` is identity); this returns `remark` to ADR-0020's
reference-fixture role with zero production runtime presence. (4) Delete the
model-to-HTML render half (`renderMarkdown`/`renderDocument` and each extension's
`renderBlock`/`renderInline`): it is production-dead and not part of the
markdown<->model spec, and its only plausible reuse -- a `remark`-rendered read
view -- would reintroduce the very divergence being removed. (5) Replace the
narrow parse-error surface with a general client-side **error boundary plus a
dismissible banner** (console logging) so unexpected failures surface instead of
failing silently; persistent server-side telemetry is deferred (RFC-0023).
Implemented by RFC-0022.

## Consequences

the Markdown and split views are always reachable, and edits are
never silently dropped; production has one display engine (`marked`) plus
`remark`'s span-finders and the DOM-to-Markdown serialiser model. The supported
subset is no longer constrained at runtime by a second parser -- it is whatever
`marked` loads and the serialiser emits, with the golden tests pinning
markdown<->model. The change refines ADR-0040/ADR-0041: the client
"round-trippable subset" validation they retained is removed; the server's
raw-HTML rejection trust boundary (ADR-0041) is unchanged, and rendering stays
browser-owned (ADR-0019/ADR-0040 hold). A residual risk is recorded honestly: the
one link that was never unit-tested -- `marked`'s real ProseMirror DOM into
`documentFromElements` -- stays manually verified in Chrome (happy-dom cannot
reproduce that DOM); offline trust does not close that gap, it stops the `remark`
gate from appearing to. Builds on ADR-0019 (server stores/serves), ADR-0020
(`remark` as reference fixture), and ADR-0041 (golden tests as the net).
