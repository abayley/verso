# Lance FTS optimize panic (lance-index 7.0.0)

Status: FIXED locally 2026-07-14 by upgrading the vendored build to
lancedb 0.31.0 / lance + lance-index 8.0.0 (the lance#7325 area fix for the
inverted index under deletions). Verification: 10/10 hang-repro storm runs
GREEN on the upgraded dylib (churned index, fresh index, and the full
integration search seam), where lance-index 7.0.0 crashed ~1 in 3 runs.
The vendored clone carries the dep bump as a commit on branch
`lance-upgrade-7325`; `spike/search/lancedb-c-fts-query.patch` now includes
the version pins, so `make search-lancedb` reproduces the fixed build (needs
rustc >= 1.94; `rustup update stable`). Still worth reporting upstream so
7.x users hit a fix, hence the notes below.

Original diagnosis (lance-index 7.0.0): kills the whole server
(Rust panic -> abort across the C FFI; nothing our side can catch).

## Symptom

During `cn_store_optimize` (the ADR-0080 async worker), lance panics and aborts
the process:

```text
thread '<unnamed>' panicked at .../lance-index-7.0.0/src/scalar/inverted/builder.rs:856:57:
index out of bounds: the len is 210 but the index is 228
...
   3: lance_index::scalar::inverted::builder::InnerBuilder::merge_from
   4: lance_index::scalar::inverted::builder::InvertedIndexBuilder::update_from_segments
   5: lance::index::append::merge_indices_with_unindexed_frags
   6: ...optimize_indices
  12: _lancedb_table_optimize
  13: _cn_store_optimize
  14: _cn_async_main
```

Two captured crashes panicked at the same site with `len is 210` both times
and a varying index (228, 215) -- a fixed-size structure indexed past its end
while merging FTS segments.

## Reproduction

`scripts/hang-repro.sh` (the RFC-0036-era storm: 20 publishes plus rounds of
create+delete against the search-demo rig) reproduces it at roughly 1 in 3
runs against an index directory with accumulated version churn. It is not
purely index-state determined: a rerun from the same on-disk index state was
GREEN, so the panic depends on the upsert/delete sequence (or its timing)
before the optimize as well.

The trigger profile matches the known lance failure mode: many small upserts
and deletes, then `optimize_indices` merging the FTS segments.

## Upstream

- Our exact panic site (`InnerBuilder::merge_from`, `builder.rs:856`) does not
  appear in the public trackers as of 2026-07-14.
- lance#7325 ("keep the inverted index correct under deletions in the
  fragment-reuse window") landed after lance-index 7.0.0 and addresses the
  same delete-then-merge area -- upgrading the vendored lancedb/lance is the
  most promising fix, and folds into the pending lancedb-c PR work.
- Related public panics in the same subsystem: lancedb/lance#4209 (FTS search
  panic), lance-format/lance#5312 (optimize panic in vector indices).

## Suggested issue text (when filing upstream)

Panic in `InnerBuilder::merge_from` (`lance-index 7.0.0`,
`src/scalar/inverted/builder.rs:856`) during `optimize_indices` on a table
with an FTS (inverted) index: `index out of bounds: the len is 210 but the
index is 228`. Workload: many small `merge_insert` upserts and deletes on a
small table (~200 rows), then `Table::optimize`. Intermittent (~1/3 of runs of
our stress harness); the panic index varies between crashes, the length does
not. Full backtrace attached.

## Local evidence

- Crash logs: two full backtraces captured 2026-07-14 (identical site).
- The storm harness: `scripts/hang-repro.sh` (GREEN/RED/CRASH classification).
- `HANG_REPRO_FRESH=1 scripts/hang-repro.sh` wipes and rebuilds the demo
  index; whether a fresh index also crashes has not been established (the
  observed crashes were against churned index state).

## Mitigation options considered

- Catching the panic is impossible: the abort crosses the FFI boundary.
- Skipping optimize entirely would degrade FTS query performance over time.
- Running optimize in a subprocess would isolate the crash but adds process
  management for a bug that an upstream upgrade likely fixes; not pursued.
