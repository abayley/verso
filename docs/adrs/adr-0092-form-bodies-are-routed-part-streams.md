---
id: ADR-0092
name: Form bodies are consumed as routed part streams
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-13
updated: 2026-09-13
supersedes: []
superseded_by: null
related_rfcs: [RFC-0012, RFC-0036, RFC-0040, RFC-0042]
---

# ADR-0092: Form bodies are consumed as routed part streams

## Context

ADR-0091 made block streaming the default for network and file I/O, and RFC-0040 applied it to every
document path but one: a form `POST` was still read whole, because the parser (`Http.parseFormBody`) took
the complete body and returned decoded fields. A form with a document-sized field therefore cost a
document-sized buffer plus decoded copies, and its byte decoder built the decoded value as a list, a shape
with a hard ceiling on the MicroHs evaluator stack. Other frameworks solve this for `multipart/form-data`
with a part-level parser and a consumer chosen per part (Node's `busboy`, Go's `multipart.Reader`,
`wai-extra`'s `BackEnd`), and treat urlencoded bodies as small. Verso's large-field form is urlencoded, and
the encoding still delivers a part's name before its value, so the same design applies.

## Decision

A form body is consumed as a **stream of parts**, and each part's value is **routed by its decoded name** to
a sink chosen before the value arrives (`MicroHttp.Form.formI`, RFC-0042). Fields with no sink of their own
are decoded and collected in memory under a per-field cap, a total cap and a count cap (`FormLimits`); a
field the application designates as large streams, still encoded, to the sink it names, and is decoded on
the way in bounded blocks (`decodeFormValueI`, and `normaliseNewlinesI` where the document contract asks).
No framework or application code parses a form from a whole-body value. The whole-body parser and its byte
decoder are removed.

Two rules follow for any form the application serves:

- **Order is part of the form's contract.** A sink is chosen when a name arrives, so the choice cannot
  depend on a field that comes later. Control fields go before the large field; browsers preserve document
  order, and the form's markup carries a note saying so.
- **Every intermediate is bounded by a block, not by the producer.** A transformer slices whatever chunk it
  is handed to a fixed size before working it, so a strict producer that delivers a whole body as one chunk
  (the test harness does) cannot reintroduce a value-length list.

## Why

- It closes the last whole-body read on a document path, so `formBodyLimit` is page-size policy only and
  the memory a save costs is a block, whichever transport the client used.
- The design is the one the field converged on, with the interface the framework already has: a part sink
  is an `Iter`, routing is a function of the name, `feedChunk` interleaves one source into several sinks,
  and `fileSinkI` is the large-field sink. Multipart, when it is needed, produces the same parts.
- The per-field and total caps close a gap the body cap alone left: a body under the cap could be one field
  of that size, decoded whole.
- The first full-size integration run found the producer-chunk hazard (a 400KB form as one chunk overflowed
  the stack) before the code shipped; slicing in the transformer fixed it for every producer at once.

## Reopens when

A `multipart/form-data` form appears. The part interface was designed for it, and the reopen is to add a
multipart parser producing the same parts, not to change the routing. Also reopens if a form ever needs a
routing decision that depends on a later field, which the order rule forbids; the answer then is to buffer
that one form deliberately, not to weaken the rule.

## Consequences

- A collected field over its cap is refused (`413`) where the old parser accepted anything under the body
  cap. Verso's save form routes its only large field, so nothing that worked stops working.
- `Http.parseFormBody` and `Http.decodeFormValueBytes` are gone; the `String` decoder stays for query
  strings. Handlers whose fields are all identifiers consume the body through `formFieldsI` in `Verso.App`,
  which is `formI` with every part collected.
- The save form's `<textarea>` must stay the last field, or any field added after it must not affect how
  the document is stored.
