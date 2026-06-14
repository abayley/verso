---
id: RFC-0013
name: HTML Response Builder
status: Draft
owners:
    - alistair
created: 2026-06-13
updated: 2026-06-13
supersedes: []
superseded_by: null
---

# HTML Response Builder

| Stage     | Timestamp  |
|-----------|------------|
| Authored  | 2026-06-13 |
| Started   |            |
| Completed |            |

## Summary

Placeholder. Replace the `String`-append-then-pack HTML rendering with a
builder that produces a tree (or sequence) of `ByteString` chunks, appended in
constant time and streamed to the socket without concatenating the whole page
into one buffer. This is a performance change only; the response contract from
RFC-0012 is unaffected. Design options are to be discussed before this RFC is
fleshed out -- in particular the concrete builder representation under MicroHs.

## Context

This RFC is a placeholder to be developed after discussion. The current
`MicroHttp.Html` is a writer monad over `String`
(`newtype Html a = Html (String, a)`, with `>>=` doing `left ++ right`), and
`TestApp` renders it and then copies the whole thing with `BS.pack` into a
single strict body. That is two layers of waste: repeated `String` (`[Char]`)
appends, then a whole-page copy.

The intended direction (from the request-lifecycle design discussion) is a
builder: HTML combinators accumulate a tree of `ByteString` chunks that
concatenates in O(1) and renders by walking the tree emitting chunks, so the
body is a stream of chunks written straight to the socket -- no whole-page
concatenation or copy. Constant tag fragments are shared with no copy; only
dynamic, escaped text allocates. This also unifies with the file-streaming
path (`fileEnumerator` already yields chunks) and, once response bodies are
chunk-streams, lets the RFC-0012 logging middleware count response bytes
through `egress` uniformly.

RFC-0012 leaves HTML rendering as-is on purpose, so this can be done
independently and later.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately
mark it as complete in the phase checklist.

## Goals

- Build HTML as a tree/sequence of `ByteString` chunks with constant-time
  append, rendered as a chunk stream rather than one concatenated buffer.
- Keep the existing combinator API (`el`, `text`, attributes, the named
  elements) source-compatible where practical.
- Fit the RFC-0012 response contract: the body becomes a chunk stream that
  flows through the writer (and `egress`).
- (To be expanded once the representation is chosen.)

## Non-Goals

- No change to the request-handling contracts from RFC-0012.
- Not necessarily zero-allocation: escaping dynamic text inherently allocates;
  the goal is no whole-page concatenation or pack-copy.
- (To be expanded.)

## Proposal

To be written after the design discussion. The central decision is the builder
representation and how it reaches the socket; see Open Questions.

## Alternatives Considered

- To be written (representation choices below).

## Security Impact

- HTML escaping of dynamic text must be preserved exactly through the change;
  the builder must not open an escaping gap. Details when fleshed out.

## Reliability Impact

- Performance change; behaviour (the rendered bytes) must be identical to the
  current renderer for the same input, which the existing `HtmlSpec` golden
  output should pin.

## Compatibility Impact

- Aims to keep the combinator API stable; the change is to the internal
  representation and to how a response body is produced. Details when fleshed
  out.

## Testing and Quality Gates

- `make check` stays green.
- The rendered output must byte-match the current renderer for existing
  `HtmlSpec` cases (golden), plus chunk-boundary cases.

## Rollout Plan

1. Placeholder; rollout to be defined after the design discussion.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC does not cover, stop changing
  the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, with evidence,
  impact, options, and a recommendation.
- Continue only after explicit reviewer or user approval.

## Open Questions

- What is the builder representation under MicroHs? Candidates: a
  difference-list / rope of `ByteString` (a small tree with O(1) append and a
  flattening walk); a `[ByteString]` accumulated in reverse; or a
  `Builder`-style function over a chunk continuation. The MicroHs `ByteString`
  behaviour flagged in the design notes needs checking before committing.
- How does the chunk tree become a response body -- a new `ResponseBody`
  constructor, a `StreamBody` fed by a chunk enumerator, or a strict body built
  by one final flatten (interim)?
- `Content-Length`: sum the chunk lengths in one cheap pass (the chunks are in
  memory, so no copy) to send an exact length, or stream close-delimited like
  files? This is the in-memory counterpart to the file-size FFI question.
- Does the `Html` monad keep its writer shape with the output type swapped from
  `String` to the builder, or move to a different formulation?
