---
id: RFC-0002
name: Editor Shell Decomposition
status: Implemented
owners:
    - alistair
created: 2026-06-10
updated: 2026-06-16
supersedes: []
superseded_by: null
---

# Editor Shell Decomposition

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-10       |
| Started   | 2026-06-15 22:08 |
| Completed | 2026-06-16 08:50 |

## Summary

Extract the cohesive behaviours inside `markdown-editor-element.ts` into
plain controller classes with the custom element as orchestrator, without
changing behaviour, before running the Lit shell spike recorded in the
Markdown editor spike document. The decomposition shrinks the element to
coordination code so the Lit spike rebuilds a small, well-factored shell and
the comparison is honest.

## Context

`markdown-editor-element.ts` is roughly 1,700 lines with about twenty-five
mutable nullable fields. It currently owns toolbar construction, a tooltip
timing engine, the link target popover and hover actions, the save state
machine and its timers, mode and theme switching, word counting, htmx form
wiring, and active-pane command routing. Each behaviour is individually
reasonable; the aggregation is the module where every new feature lands by
default, and it is the main complexity named in the spike document's Lit
findings.

The spike document defines the Lit decision test: rebuild only the toolbar
rendering plus save and link popover state in Lit, keep the Tiptap and
CodeMirror adapters unchanged, then compare clarity, test stability, Web
Awesome interop, and cost. That comparison is distorted if the current shell
mixes extractable state machines into one class: Lit would get credit for
ordinary refactoring. Decomposing first isolates what Lit is actually being
evaluated for, which is declarative rendering of toolbar, notice, and
popover state.

This is a refactor, not a behaviour change. Under the project test policy the
existing element-seam tests and the browser smoke flow are the safety net;
no new tests are added and none should need to change.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Reduce `markdown-editor-element.ts` to lifecycle, mode and theme switching,
  pane command routing, and controller wiring.
- Give each extracted controller a small explicit interface: inputs as
  constructor dependencies, observable outcomes as return values or
  callbacks.
- Keep every existing unit test and the browser smoke flow passing without
  modification.

## Non-Goals

- No Lit adoption; that decision belongs to the spike this RFC precedes.
- No new editor features and no visual changes.
- No changes to the Tiptap or CodeMirror adapters or the Markdown model
  modules.
- No test additions or rewrites; a refactor that forces test changes is
  overstepping the seam.

## Proposal

Extract three controllers as plain classes in `src/TestApp/Editor/`, one
slice at a time, with checks run between slices.

- Save state controller: owns the `clean`, `dirty`, `saving`, and `retry`
  states, the minimum-saving-time transition, and the save timeout. The
  element forwards htmx lifecycle events and content-change notifications;
  the controller reports the current state, button label, disabled flag, and
  error text through a change callback. The state machine logic becomes
  data-in/data-out with timers at the edge.
- Toolbar tooltip controller: owns the shared tooltip element, the show and
  hide delays, and warm retargeting between controls. The element registers
  controls with it.
- Link popover controller: owns the link target editor, the existing-link
  hover actions, the hide grace timer, and the pending visual or source
  selection captured when the popover opens. The element supplies the
  adapters' selection capture and apply functions.

Toolbar construction stays in the element for now: it is creation-time code
rather than mutable state, and it is the part the Lit spike replaces
wholesale. If a controller extraction reveals further cohesive seams, record
them here rather than extracting opportunistically.

Sequencing: run this after RFC-0001 phase two, because progressive
enhancement deletes element plumbing (the hidden-field copy hook and the
edit-page fetch) that would otherwise be moved during extraction, and before
the Lit spike for the reasons in the context section.

## Alternatives Considered

- Run the Lit spike against the current shell: conflates refactoring gains
  with framework gains and inflates the spike's apparent benefit.
- Adopt Lit directly without a spike: contradicts the decision test already
  recorded in the spike document.
- Split the element into multiple custom elements: public boundary churn for
  internal organisation; plain classes achieve the separation without
  changing the page contract.

## Security Impact

- None expected; no contract, parsing, or escaping changes.

## Reliability Impact

- Timer ownership moves into controllers; each controller must expose a
  `dispose` path so `disconnectedCallback` cleanup remains complete.
- The known cleanup gap (the source editor is not destroyed on disconnect)
  should be fixed while lifecycle code is being touched.

## Compatibility Impact

- No changes to element attributes, events, classes, or form behaviour; all
  existing selectors and tests remain valid.

## Testing and Quality Gates

- `make check` after every extraction slice.
- `make test-editor-browser` after the final slice.
- The refactor is complete only if both pass with no test modifications.

## Rollout Plan

1. Phase one: extract the save state controller.
   - [x] Moved save states, timers, and labels behind `SaveStateController`
         (`save-state-controller.ts`); the element renders a reported view and
         forwards htmx lifecycle + content-change. All tests pass unmodified.
   - [x] Fixed the source-editor destroy gap in `disconnectedCallback` (and the
         save timers are now disposed there via `controller.dispose()`).
2. Phase two: extract the toolbar tooltip controller.
   - [x] Moved tooltip element, timing, and warm retargeting behind
         `ToolbarTooltipController` (`toolbar-tooltip-controller.ts`); the element
         registers controls. All tests pass unmodified.
3. Phase three: extract the link popover controller.
   - [x] Moved the link target editor, hover actions, hide grace timer, pending
         selections, and document pointer wiring behind `LinkPopoverController`
         (`link-popover-controller.ts`); the element supplies positioning and the
         editor-adapter operations through a host interface. All tests and the
         browser smoke pass unmodified.
   - [x] Recorded module sizes in the spike document (element 2103 -> 1642 lines;
         controllers 164 + 119 + 324) and confirmed readiness for the Lit spike.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts
  do not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

Resolved before implementation (2026-06-15):

- **Timer seam:** keep direct `window` timers. The existing tests drive them
  with `vi.useFakeTimers`, which patches `window` globally, so an injected seam
  would add indirection without testability gain.
- **Word count:** stays element code. It is not save state; the element keeps
  computing it on content change.

Resolved during phase three (2026-06-15):

- **Shared overlay positioning.** RFC-0016 (added after this RFC was authored)
  made `positionOverlay` / `activeEditPaneRect` shared by the bubble toolbar and
  slash menu, not just the link popover. Resolved as proposed: the element keeps
  `positionOverlay`/`activeEditPaneRect` (used by all three surfaces) and passes
  positioning to `LinkPopoverController` through a `LinkPopoverHost` interface,
  alongside the adapter selection-capture/apply callbacks and the visual-anchor
  resolution. The controller owns the document pointer dismissal/hover wiring and
  disposes it on disconnect. The positioning helper is not duplicated.
