---
id: ADR-0072
name: Concordance Search Engine Behind a Project C Shim
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0034]
---

# ADR-0072: Concordance Search Engine Behind a Project C Shim

> Status: Accepted (RFC-0034).

## Context

RFC-0034 adds hybrid (semantic plus BM25 full-text) search over the
document tree. The engine must be reusable beyond Verso, scale past the
current corpus, and respect MicroHs's FFI limits: only static `ccall` imports
of flat functions over scalars and pointers -- no function-pointer tables and
no Arrow C ABI structures.

## Decision

The engine is a separate library namespace, `Concordance.*`
(`Verso.*` may depend on `MicroHttp.*` and `Concordance.*`; `Concordance.*`
depends on neither). Storage and retrieval use LanceDB through the official
`lancedb-c` bindings -- carrying a small local patch that adds the missing
full-text and hybrid query entry points until it is upstreamed -- wrapped in
a project-owned C shim (`cbits/concordance_shim.c`) that uses nanoarrow
internally so no Arrow structure crosses the FFI boundary. A no-dependency
stub (`cbits/concordance_stub.c`) implements the same header and is linked
whenever `make search-shim` has not run, so every build target works without
the optional toolchain (Rust, ONNX Runtime, model files) and search reports
itself unavailable at runtime.

## Consequences

`make check` needs no search toolchain; search is off by
default (`search_enabled`). The shim's ownership rules follow lancedb-c's
observed semantics (execute and to-arrow consume their inputs), and an empty
query result returns a NULL Arrow schema that the shim must not touch.
In-process native code means a shim bug can crash the whole server -- the
shim is deliberately small, and the out-of-process worker remains the
documented fallback.
