---
id: ADR-0084
name: Content Pipelines Are Built From Explicit Extension Sets
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0084: Content Pipelines Are Built From Explicit Extension Sets

> Status: Accepted (2026-08-07).

## Context

ADR-0041 introduced a module-global content-extension registry filled
by import side effects. Production imports the common extensions and then the
editor host registers raw HTML and badge support by call timing. Tests use a
third path and rely on module isolation to keep their extension selections
apart. The selected policy is therefore hidden in imports, mutable state, and
initialisation order. A generic content mode would make the policy more
visible, but "mode" already names document-tree mode and the editor's view
modes.

## Decision

Each content pipeline is built from an explicit, immutable, named
feature-extension set. Production and tests name their complete feature sets at
their composition sites. The pipeline accepts an extension set rather than a
generic mode flag. Module-global registration, import-side-effect registration,
and registration by call timing are removed.

The content pipeline owns the mdast-to-model, DOM-to-model, and
model-to-Markdown registry walks, their recursion, extension ordering, and
remark plugin collection. The remark adapter's test-only Markdown parsing path
receives a content pipeline rather than becoming part of it. The adapter's
production protected-fragment span finders remain separate from that path. The
pipeline always installs the base extension last; callers select feature
extensions and cannot replace the base. An empty feature set is valid.

Construction preserves the caller's feature-extension order and rejects
duplicate extension names with a descriptive error. The pipeline never
silently keeps one duplicate. These checks apply to invalid program
configuration, not Markdown input.

Custom block and inline payloads use an extension-keyed TypeScript payload map.
Each extension checks mdast or DOM input before constructing its payload, and
the pipeline gives a serialisation handler its own payload type without a cast.
The pipeline does not add runtime payload schemas because extension payloads
are internal values rather than a stored or external data format.

The payload map is an open TypeScript interface. Each in-tree extension adds
its key and separate block or inline payload types through declaration merging.
The common editor document and node types remain non-generic, and adding an
extension does not require a central model edit. Declaration merging adds no
runtime registration or initialisation order.

Mdast and DOM recognition remain ordered extension walks because several
extensions may inspect the same input. A custom model node already names its
owner, so model-to-Markdown serialisation looks up that extension directly and
passes the handler its narrowed payload. If the active extension set lacks the
named extension, serialisation preserves ADR-0041's fail-soft empty result.

The editor bundle's composition root builds one immutable
`documentTreeContentPipeline` and passes it to editor adapters. Low-level
conversion modules do not select a hidden default, and individual editor
elements do not rebuild equivalent pipelines. Extension tests construct a
pipeline with the extension under test. General pipeline tests use the common
feature set, while document-tree integration tests use the full production set
including raw HTML and badges.

Callout is the family term. Its two variants are GFM alert and MkDocs
collapsible. Active code removes the ambiguous "admonition" name and uses
`GfmAlert`, `GfmAlertKind`, and the `gfm-alert` extension key. The transient
editor model key is neither stored nor exchanged outside the browser pipeline,
so the rename changes internal identifiers and test expectations without
changing saved Markdown or user-visible behaviour. Historical RFCs and ADRs
retain their original wording.

GFM alert and MkDocs collapsible remain separate extensions because their
grammar, state, DOM, and editing behaviour differ. A shared callout module owns
only their actual common concepts: `CalloutKind`, the five supported kinds,
default titles, and class decoding. It does not introduce a generic configured
callout extension. The duplicate Markdown line quoting belongs to the base
blockquote and GFM alert serialisers, so a separate neutral helper may serve
those two callers.

The pass-through `markdown-parse.ts` and `markdown-serialise.ts` modules and the
legacy `markdown-parse-local.ts` grammar are deleted. Callers use the explicit
content pipeline or remark adapter directly, with no compatibility wrappers and
no replacement independent grammar. Expected-model and round-trip cases become
pipeline tests, while a focused remark adapter test proves that the adapter uses
the supplied pipeline.

`createContentPipeline(featureExtensions)` returns a read-only interface with
four document-level capabilities: the remark plugin list, mdast-to-document
conversion, DOM-to-document conversion, and document-to-Markdown serialisation.
The module keeps single-node conversion, recursion, lookup tables, and the base
extension private. The factory returns an object rather than a public class, and
callers cannot inspect or mutate a registry.

An extension input handler returns its typed data and optional children rather
than a complete custom model node. The pipeline adds the `custom` node type and
the descriptor's extension key. The descriptor name is therefore the only
source of a custom node's identity, so an extension cannot pair another
extension's key with its payload.

Implementation uses separate green phases and commits. The phases establish
the tested pipeline factory; cut production and tests over while removing
global registration; add typed payload ownership; delete the legacy modules;
then consolidate and rename callout code. Each phase starts with tests at the
public seam and ends with the full project check. Temporary migration code may
exist within a phase, but no committed phase retains two production composition
mechanisms.

The change preserves observable Markdown behaviour. Parsing, DOM conversion,
serialisation, extension ordering, errors, and round-trip output remain the
same. Intentional changes to Markdown behaviour require a separate decision
and test case.

One RFC owns the work, with separate phases and commits for explicit pipeline
construction, typed extension payloads, deletion of pass-through and legacy
test modules, and shared callout code. Callout consolidation is last because
the new pipeline does not depend on it.

## Consequences

A caller or test can identify its extension policy from one
value, and tests no longer depend on file-level module isolation. Extension
ordering becomes part of the named extension set. ADR-0041's in-tree,
build-time extension boundary, fallback extension, strict parse behaviour,
and fail-soft serialisation remain in force. This decision amends only
ADR-0041's global registration mechanism. ADR-0051's test-only remark contract
is unchanged.
