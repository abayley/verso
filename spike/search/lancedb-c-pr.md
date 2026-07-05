# Prepared PR: lancedb-c Full-Text and Hybrid Search

Status: prepared 2026-07-05, awaiting review and submission by the repo
owner. The change lives on the `fts-query-api` branch of the local clone at
`vendor/search/lancedb-c` (commit on top of upstream `36bb519`), and the
same diff is captured in
[lancedb-c-fts-query.patch](lancedb-c-fts-query.patch).

## Submitting

```sh
# from vendor/search/lancedb-c, after forking lancedb/lancedb-c on GitHub
git remote add fork git@github.com:<you>/lancedb-c.git
git push fork fts-query-api
gh pr create --repo lancedb/lancedb-c --head <you>:fts-query-api \
  --title "feat(query): expose full-text and hybrid search" \
  --body-file <this file's PR body section>
```

## Suggested PR Body

The C API can create an FTS index (`lancedb_table_create_fts_index`) but
has no way to run a match query against it, and no hybrid search. This PR
exposes the engine capabilities that the Python and TypeScript SDKs already
surface:

- `lancedb_query_full_text_search(query, text, columns, num_columns, err)`
  -- set a BM25 match query on a plain query; `lancedb_query_execute`
  then returns rows ranked by relevance in a `_score` column.
- `lancedb_vector_query_full_text_search(...)` -- set the FTS component on
  a vector query, making it hybrid.
- `lancedb_vector_query_execute_hybrid(query)` -- run
  `VectorQuery::execute_hybrid` (vector + FTS combined with the engine
  default reranker, reciprocal rank fusion); rows carry a
  `_relevance_score` column.

`columns` may be NULL to search all FTS-indexed columns. `lance-index` is
added as a direct dependency for `FullTextSearchQuery`; it is already in
the dependency graph via `lancedb`.

Tests: a new Catch2 test case in `tests/test_query.cpp` covering the FTS
match path (`_score` present, correct row), NULL-columns search, NULL-text
invalid argument, hybrid combination (`_relevance_score` present, both
arms contribute), and hybrid-without-FTS returning NULL. All existing and
new query tests pass (13593 assertions in 6 test cases, macOS arm64).

Notes for reviewers:

- `lancedb_vector_query_execute_hybrid` consumes the query pointer, same
  as the existing `lancedb_vector_query_execute`.
- Follow-up candidates, deliberately out of scope: exposing the RRF `k`
  parameter / reranker selection, and FTS query options (fuzziness,
  boosting).

## Possible Follow-Up Issues (separate from the PR)

1. Header does not compile as plain C: `LanceDBObjectStoreRegistry` is
   referenced without a struct tag or typedef (C++ only). One-line fix.
2. Header comments on `lancedb_query_result_free` /
   `lancedb_vector_query_free` suggest freeing after
   `lancedb_query_result_to_arrow` / execute, but those functions consume
   their inputs; following the comments double-frees. Documentation fix.
3. `LanceDBFtsIndexConfig.language` expects tantivy-style names
   ("English"); ISO codes ("en") return InvalidArgument with no hint.
