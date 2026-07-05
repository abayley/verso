# Verso Search Runbook

Operating notes for Concordance search (RFC-0034, ADR-072..074).

## Enabling Search

1. Build the optional pieces once per machine: `make search-lancedb` (needs
   Rust), `make search-model`, `make search-shim` (needs
   `brew install onnxruntime`).
2. Configure: `search_enabled = true`, `search_model` and `search_vocab`
   pointing at the files under `vendor/search/<platform>/model/`, and
   optionally `search_index` (default `data/search_index`).
3. Start the server. The log reports `search: enabled` and the startup
   reconcile enqueues every unindexed page; first-time indexing of a large
   tree takes minutes in the background (the `/search` page shows the
   pending count meanwhile).

Search stays off (with a log line saying why) when the shim is the stub or
the model/store cannot be opened; the server runs on regardless.

## Rebuilding the Index From Scratch

Stop the server, delete the `search_index` directory, and restart: the
startup reconcile re-indexes everything. The same happens automatically when
`search_model_id` changes (embeddings from different models are
incommensurable).

## Freshness Repairs

`POST /index/refresh` re-establishes freshness for all derived indexes (link
index and search) after out-of-band edits: it stat-sweeps the tree, content-
hashes only stat-changed pages, and re-embeds only real changes. Worker
failures are logged (`search: index <page> failed: ...`) and retried by the
next reconcile.

## Cost Model

Measured on macOS arm64 (spike notes): ~30 ms per 384-token chunk embed and
2-3 ms per query embed (bge-small int8, 4 threads). Every shim call blocks
the whole MicroHs runtime for its duration; the worker yields between chunk
embeds, so a large backlog degrades to request stutter, never a freeze.
