---
id: ADR-0073
name: In-Process ONNX Embedding With a Configured Model Profile
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0034]
---

# ADR-0073: In-Process ONNX Embedding With a Configured Model Profile

> Status: Accepted (RFC-0034).

## Context

Indexing and queries must embed text identically, on CPU, inside a
cooperatively scheduled runtime where every C call blocks all green threads.

## Decision

Embeddings run in-process through the ONNX Runtime C API (a shim
function; ORT's function-pointer-table API cannot be called directly from
MicroHs). The tokeniser is pure Haskell (`Concordance.WordPiece`, BERT
WordPiece, validated against HuggingFace reference fixtures). The model is a
configured profile -- path, pooling, dimensions, token cap, threads, query
prefix -- not a constant; the default is `bge-small-en-v1.5` quantised (int8,
4 intra-op threads: ~30 ms per 384-token chunk, 2-3 ms per query embed,
measured). The store records the model id; a mismatch on open invalidates
the index and forces a full rebuild, because vectors from different models
are incommensurable.

## Consequences

model files are fetched (`make search-model`, checksum-pinned),
never committed. Switching models is a config change plus an automatic
rebuild. Every embed blocks the runtime briefly, so bulk work must yield
between calls (ADR-0074).
