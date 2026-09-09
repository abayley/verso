---
id: ADR-0068
name: Separate the MicroHttp Framework From the Verso Application
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0030]
---

# ADR-0068: Separate the MicroHttp Framework From the Verso Application

> Status: Accepted (RFC-0030).

## Context

the `MicroHttp.*` namespace intermingled a general-purpose web framework
(HTTP, sockets, server, router, static, middleware, logging, HTML, config,
filesystem primitives) with a Markdown wiki application (link index, document
tree, listings, metadata, attachments, move/delete, operation log, trash, and the
routed assembly). The framework had no dependency on the application, so the
intermingling was naming, not coupling.

## Decision

keep the framework under `MicroHttp` and move the application to a new
`Verso` namespace, with a strict downward dependency (`Verso.*` may import
`MicroHttp.*`; never the reverse). Specifics:

- `MicroHttp.FileOps` is a generic libc filesystem shim shared by framework log
  rotation and the application; it stays in the framework, renamed
  `MicroHttp.FileSystem`.
- `MicroHttp.Config` keeps the generic parser, typed lookups, and a
  prefix-and-key-scoped environment overlay. The application owns its keys in
  `Verso.Config` (typed `VersoConfig`) and orchestrates the load. Server keys are
  overridden by `MICROHTTP_<KEY>` and application keys by `VERSO_<KEY>`; the two
  overlays own disjoint key sets so neither leaks into the other.
  `MICROHTTP_CONFIG` (the config-file path) is unchanged.
- The assembly `MicroHttp.TestApp` becomes `Verso.App`; the executables become
  `src/Verso/Main.hs` and `src/Verso/ReplayTool.hs`; the build target is
  `make run-verso` producing `build/verso`. The editor TypeScript moves to
  `src/Verso/Editor/` (served bundle path unchanged).

## Consequences

the framework is reusable by a different application; the two
namespaces document the boundary. Name mapping for older records:
`MicroHttp.TestApp` -> `Verso.App`, `MicroHttp.FileOps` -> `MicroHttp.FileSystem`,
the ten domain modules `MicroHttp.{DocumentLinks, LinkIndex, LinkIndexStore,
LinkFingerprint, DocumentListing, DocumentMeta, Attachment, TreeMove,
OperationLog, Trash}` -> `Verso.*`. Implemented and historical RFCs predating this
split keep their original module names as point-in-time records.
