---
id: ADR-0080
name: Search Store Mutations on a Shim Worker Thread
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0080: Search Store Mutations on a Shim Worker Thread

> Status: Accepted (2026-07-13).

## Context

Every FFI call blocks the whole single-threaded MicroHs runtime.
The search re-index drain ends with LanceDB's optimize pass, whose
version-cleanup step walks every dataset version accumulated since the
last pass -- observed at ~4.7s on the production index, during which no
request (e.g. the read view the editor navigates to after Publish) could
be served. Confirmed by sampling the live server mid-stall:
`cn_store_optimize -> lancedb_table_optimize -> cleanup_old_versions`.

## Decision

Store mutations (upsert, delete, optimize) run on a dedicated
worker thread inside the Concordance shim (cn_async_* in
concordance_shim.c). A submit copies its arguments into the shim's job
slot and returns immediately; the worker performs the LanceDB call and
writes one byte to a completion pipe; the calling green thread parks on
that descriptor with System.IO.FD.waitForReadFD -- the same mechanism the
socket layer uses -- and then collects the result. Exactly one job is in
flight at a time; Concordance.Store serialises green threads over the
slot with an MVar in the Store handle. The worker never touches the
Haskell heap (the runtime has no locks); LanceDB handles the concurrency
between the worker's writes and interpreter-thread queries. Reads
(search, listing) and ONNX embedding stay synchronous: they are short
and user-initiated.

## Consequences

A store mutation of any duration no longer stalls request
serving -- the seam test pins the longest observable stall during a
multi-hundred-millisecond optimize to scheduler noise (was: the whole
call). The stub implements the async API as cleanly unavailable, so
non-search builds still link. A wedged LanceDB call now hangs only the
queue worker's green thread, not the server (strictly better than
before, ADR-0078's failure mode). The GHC coverage builds share the same
code path (the ghc-compat FD shim provides waitForReadFD).
