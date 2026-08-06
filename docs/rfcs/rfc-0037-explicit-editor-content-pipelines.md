---
id: RFC-0037
name: Explicit Editor Content Pipelines
status: Accepted
owners:
    - alistair
created: 2026-08-07
updated: 2026-08-07
supersedes: []
superseded_by: null
---

# Explicit Editor Content Pipelines

| Stage    | Timestamp  |
|----------|------------|
| Authored | 2026-08-07 |
| Started  | 2026-08-07 |

## Summary

Replace the module-global editor content extension registry with immutable
content pipelines built from explicit feature-extension sets. Each pipeline
owns Markdown parsing, DOM conversion, Markdown serialisation, extension
ordering, and remark plugins behind one small interface. The change also gives
each extension its own typed custom-node payload, deletes three legacy wrapper
and parser modules, and moves the shared GFM alert and MkDocs collapsible terms
into a Callout module. Saved Markdown and user-visible editor behaviour remain
unchanged.

## Context

ADR-084 accepts the complete design for architecture review item 8. The current
registry stores process-wide mutable state, and extensions register through
import side effects or call timing. Production and tests therefore select
extension policy through hidden initialisation order. Every extension also
casts `data: unknown` to its own payload type during serialisation.

The current test-only Markdown path includes two pass-through modules and a
separate local Markdown grammar. The wrappers add no behaviour, and the local
grammar duplicates part of the remark grammar. GFM alerts and MkDocs
collapsibles also duplicate their five kinds, titles, class decoding, and parts
of their Markdown output despite belonging to the same Callout family.

## Phase Item Completion Instructions

Update this plan document as work progresses. Mark each item complete as soon
as its test or implementation step is complete. Each phase must end with
`make check` and a commit. No committed phase may retain two production
composition mechanisms.

## Goals

- Make each active extension set explicit and immutable.
- Put all conversion registry walks and recursion behind one content pipeline
  interface.
- Preserve the caller's feature order and always install the base extension
  last.
- Reject duplicate extension names during pipeline construction.
- Give every in-tree extension a typed block or inline payload without casts.
- Keep extension identity under pipeline control.
- Delete the wrapper modules and the separate local Markdown grammar.
- Use Callout, GFM alert, and MkDocs collapsible names in active code.
- Preserve all current Markdown, DOM, and editor behaviour.

## Non-Goals

- Runtime or third-party extension loading.
- A generic content mode or a generic configured Callout extension.
- Runtime schemas for extension payloads.
- Changes to saved Markdown or user-visible Callout behaviour.
- Moving production protected-fragment span finding into the content pipeline.
- Replacing remark or the editor's existing Markdown engines.

## Proposal

### Content pipeline interface

`createContentPipeline(featureExtensions)` returns a read-only
`ContentPipeline` interface with four document-level capabilities:

- the remark plugin list;
- mdast-to-document conversion;
- DOM-to-document conversion; and
- document-to-Markdown serialisation.

The module keeps individual-node conversion, recursion, lookup tables, and the
base extension private. Construction copies the supplied feature list, keeps
its order, rejects duplicate names with a descriptive error, and installs the
base extension last. An empty feature set is valid.

The remark adapter remains separate because it owns the test-only Markdown to
mdast step. Its `parseMarkdownWithRemark` function receives a content pipeline
and converts the parsed tree through that pipeline. Production span finders in
the same module remain independent.

### Content extension inputs

Mdast and DOM handlers return their typed payload and optional children. They
do not construct a complete custom model node. The pipeline stamps `type:
"custom"` and the descriptor's extension name, so one extension cannot claim
another extension's identity.

Recognition remains an ordered walk because several extensions may inspect the
same mdast or DOM input. A custom model node already has its owning extension
name, so Markdown serialisation uses a direct lookup. A missing active extension
keeps the accepted fail-soft empty result.

### Typed payload ownership

The editor model declares an open `ContentExtensionPayloads` interface. Each
extension adds its own key through TypeScript declaration merging, with separate
block and inline payload types where needed. The common document and node types
remain non-generic. The content extension descriptor is keyed by its declared
name, so its serialisation handlers receive only their own payload types.

Payloads are internal values made by checked mdast or DOM handlers. Runtime
payload schemas would add validation to an internal handoff without protecting
a stored or external format, so the pipeline relies on the TypeScript contract.

### Production composition

The editor composition root builds one immutable
`documentTreeContentPipeline` from the full ordered feature set, including raw
HTML and badges. Editor adapters receive that value instead of rebuilding it or
selecting extensions through imports. Extension tests build a pipeline with the
extension under test. General pipeline tests use the common feature set.

The production feature order stays identical to the current registration
order. Raw HTML and badges remain the final feature extensions before the base
extension.

### Legacy module deletion

Delete `markdown-parse.ts`, `markdown-serialise.ts`, and
`markdown-parse-local.ts`. Tests and callers import the content pipeline or
remark adapter directly. Expected-model and round-trip cases become content
pipeline tests. One focused remark adapter test proves that the adapter uses the
supplied pipeline. No replacement independent Markdown grammar is added.

### Callout language and shared code

Callout is the family term. GFM alert and MkDocs collapsible are the two
variants. Active code replaces Admonition names with `GfmAlert`,
`GfmAlertKind`, and the `gfm-alert` extension key. The internal key change does
not affect saved Markdown or user-visible output.

A shared Callout module owns `CalloutKind`, the five supported kinds, default
titles, and class decoding. GFM alert and MkDocs collapsible remain separate
extensions because their grammar, editor state, DOM, and editing behaviour are
different. A small neutral helper may own Markdown blockquote line emission for
the base blockquote and GFM alert serialisers.

## Alternatives Considered

- Keep the global registry and reset it in tests. The extension policy would
  remain hidden in mutable state and initialisation order.
- Pass a generic mode flag to conversion functions. A mode would hide the
  actual feature set and conflict with established document-tree and view mode
  terms.
- Make the document model generic over its extension map. Generic parameters
  would spread an internal extension concern through every document caller.
- Add runtime payload schemas. The payloads never cross a storage, network, or
  untrusted input boundary after an extension recognises the source node.
- Merge GFM alerts and MkDocs collapsibles into one configured extension. Their
  grammar, DOM, and editor behaviour differ, so the combined interface would be
  wider without hiding common behaviour.
- Keep compatibility wrappers for deleted modules. The wrappers would preserve
  shallow interfaces and allow hidden default pipeline selection to return.

## Security Impact

- The raw HTML extension remains part of the production document-tree pipeline.
- The server's raw HTML trust boundary from ADR-041 is unchanged.
- The pipeline does not load runtime extensions or accept external payload
  descriptors.

## Reliability Impact

- Duplicate extension names fail during construction with the duplicated name
  in the error.
- Immutable pipeline instances remove test order and import order dependence.
- Strict parse behaviour and fail-soft serialisation remain unchanged.
- Every phase keeps one production composition path and ends with the full
  project check.

## Compatibility Impact

- Saved Markdown, rendered DOM, editing behaviour, and round-trip output remain
  unchanged.
- Active internal identifiers change from Admonition to GFM alert.
- Tests and internal callers must import the pipeline or remark adapter after
  the three legacy modules are deleted.
- Historical RFCs and ADRs keep their original terms.

## Testing and Quality Gates

- Run `make check` before implementation and at every phase boundary.
- Use one red, green, refactor cycle for each new behaviour.
- Test the public content pipeline interface rather than private registry walks.
- Keep existing exact round-trip expectations unchanged.
- Run `make test-editor-browser` after the final production and Callout cutover.
- Run `git diff --check` before every commit.

## Rollout Plan

### Phase 1: Content pipeline factory

- [x] Test: given an empty feature set, when Markdown is parsed and serialised
      through a pipeline, then base Markdown is preserved.
- [x] Test: given ordered feature extensions, when a node is recognised, then
      handlers run in supplied order and the base extension remains last.
- [x] Test: given duplicate extension names, when a pipeline is constructed,
      then construction fails with a descriptive error.
- [x] Implement `ContentPipeline` and `createContentPipeline`, keeping
      single-node conversion, recursion, and the base extension private.
- [x] Make the remark adapter accept an explicit content pipeline.
- [x] Run `make check` and commit the phase.

### Phase 2: Explicit production and test composition

- [x] Test: given two pipelines with different feature sets, when both run in
      one process, then neither pipeline changes the other.
- [x] Test: given a custom model node, when its named extension is active, then
      only that extension serialises it.
- [x] Test: given a custom model node whose extension is absent, when it is
      serialised, then the accepted empty result is preserved.
- [x] Define the common and document-tree feature sets in composition modules.
- [x] Pass the production document-tree pipeline into editor adapters.
- [x] Convert tests to construct their complete feature sets explicitly.
- [x] Remove `registerExtension`, import-side-effect registration, and mutable
      module state before the phase commit.
- [x] Preserve the current full production extension order.
- [x] Run `make check` and commit the phase.

### Phase 3: Typed extension payloads

- [x] Test: given a block or inline handler, when the pipeline creates and
      serialises its custom node, then the handler receives its declared payload
      and the pipeline stamps the extension identity.
- [x] Add the open extension payload map and declaration merging for every
      in-tree extension.
- [x] Change mdast and DOM handlers to return payloads and optional children
      instead of complete custom nodes.
- [x] Use direct extension lookup for custom-node Markdown serialisation.
- [x] Remove every extension payload cast and keep common model types
      non-generic.
- [x] Run `make check` and commit the phase.

### Phase 4: Legacy parser and wrapper deletion

- [x] Test: given the current supported Markdown and DOM cases, when callers use
      the pipeline or remark adapter directly, then table, GFM alert, MkDocs
      collapsible, footnote, reference link, image, raw HTML, and badge results
      remain exact.
- [x] Test: given a supplied pipeline, when the remark adapter parses Markdown,
      then it uses that pipeline for mdast conversion.
- [x] Move expected-model and round-trip cases to pipeline-facing tests.
- [x] Delete `markdown-parse.ts`, `markdown-serialise.ts`, and
      `markdown-parse-local.ts` without adding a replacement grammar.
- [x] Remove every import of the deleted modules.
- [x] Run `make check` and commit the phase.

### Phase 5: Callout consolidation and active-code rename

- [ ] Test: given each supported Callout kind, when GFM alert and MkDocs
      collapsible Markdown and DOM are converted, then their current output is
      unchanged.
- [ ] Test: given base blockquotes and GFM alerts, when they are serialised,
      then quoted-line output remains exact.
- [ ] Add the shared Callout module for kinds, default titles, and class
      decoding.
- [ ] Rename active Admonition identifiers, commands, Tiptap nodes, tests, and
      extension keys to GFM alert terms.
- [ ] Keep GFM alert and MkDocs collapsible as separate extensions.
- [ ] Extract a neutral quoted-line helper only if both current serialisers use
      it without widening their interfaces.
- [ ] Run `make check`, run `make test-editor-browser`, mark this RFC
      implemented, move it to `docs/rfcs/implemented`, and commit the phase.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or ADR-084 does not cover,
  stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- None. ADR-084 records the accepted design, and the user accepted this RFC for
  implementation on 2026-08-07.
