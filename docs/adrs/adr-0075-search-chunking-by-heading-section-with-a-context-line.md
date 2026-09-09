---
id: ADR-0075
name: Search Chunking by Heading Section With a Context Line
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0034]
---

# ADR-0075: Search Chunking by Heading Section With a Context Line

> Status: Accepted (RFC-0034).

## Context

The search index's retrieval unit (the **chunk**) determines both
retrieval quality and index compatibility: every choice here is baked into
every stored vector, so changing the strategy later means re-embedding the
whole tree. The unit must suit a wiki whose pages are heading-structured
Markdown with substantial code-fence content, and whose results should
deep-link to a section, not just a page.

## Decision

- **A chunk is one ATX heading section** of a page (the pre-heading preamble
  is a chunk with an empty anchor), identified by page path, heading text,
  and sequence number. Sections beyond the size cap split at paragraph
  boundaries with contiguous sequence numbers; a single oversize paragraph
  stays whole. There is **no overlap** between chunks in this version.
- **One stored text serves full-text search, embedding input, and the
  result excerpt alike**: a context line -- the page title plus the
  @ > @-joined *ancestor* heading path (the chunk's own heading already
  opens its section text; a split continuation adds its own heading to the
  context, since the heading line is absent from its piece) -- followed by
  the section's Markdown with frontmatter stripped and code/Mermaid
  **fences kept** (fence content is exactly what an ops wiki's full-text
  queries look for). Title conditioning materially improves embedding
  retrieval, and putting it in the one text makes titles full-text
  searchable with no separate column.
- **Chunking is fence-aware throughout**: a heading-looking line (a @#@
  shell comment) or a blank line inside a code fence never starts a section
  or a paragraph split, so fences survive intact in one chunk.
- **The cap is ~384 tokens** (retrieval granularity degrades past this
  regardless of the model's 512-token window), implemented as a ~1500
  character proxy so the chunker needs no tokeniser; the embedding path
  truncates at the true token cap regardless.

## Consequences

excerpts show the context line and raw Markdown (accepted;
the result renderer can soften later). No overlap means a topic straddling
a section boundary can rank lower than ideal -- revisit with overlap or
semantic splitting only on real query evidence, and expect a full re-embed
when the strategy changes. The implementation is the pure
`Verso.SearchChunks`, unit-tested per rule above.
