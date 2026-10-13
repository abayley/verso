# MicroHttp Documentation Map

This file says what each documentation directory holds and where a new document goes. Filing a document
in the wrong place is easy to do and hard to notice, so the rules below are meant to be read before
adding anything to `docs/`. The structure follows the standard used in the `aria-recite` project.

## Documentation Directory Map

| Directory            | Holds                                                                              |
| -------------------- | ---------------------------------------------------------------------------------- |
| `docs/architecture/` | Explanation. How the system is put together and why, written to be read end to end |
| `docs/guides/`       | How-to. Task-shaped instructions for someone who already knows what they want      |
| `docs/reference/`    | Reference. Catalogues of config keys and benchmarks, read by lookup                |
| `docs/adrs/`         | Decision records. One decision per file, append-only, the decision register        |
| `docs/rfcs/`         | Proposals. How each piece gets built, with its own lifecycle and index             |
| `docs/rfcs/refs/`    | Supporting material for a specific RFC: spikes, evidence, split-out design notes   |
| `docs/reviews/`      | Point-in-time reviews: of an RFC's change set, the codebase, or the documentation  |
| `docs/mockups/`      | HTML design prototypes; the Moebius watercolour prototype is a tuning reference    |

The first three rows are Diataxis document types, which classify a document by how it is used rather than
by who reads it. The rest are records, classified by being point-in-time rather than by use. There is no
`docs/tutorials/` or `docs/slides/` yet; add one with its first document rather than in advance.

`docs/architecture/initial-module-design/` is a frozen artifact: the starter per-module design, kept as a
historical record and not updated. Do not edit it to reflect current code; write current explanation in
`docs/architecture/` instead.

## Documentation Filing Rules

Four questions decide where a document goes, and each has a determinate answer.

### Explanation Or Instruction

If the document explains how something works and why, it is explanation and belongs in
`docs/architecture/`. If it tells someone how to carry out a task they have already chosen, it is a
how-to and belongs in `docs/guides/`. A document that does both should usually be split, because the
person reading for understanding and the person reading to get something done want different things.

### RFC Or ADR

An RFC proposes how to build something and is the venue for review. An ADR records that a decision was
made and why, and stays in force until something supersedes it. An accepted RFC often produces one or
more ADRs for the choices that matter beyond its own implementation. A decision made outside any RFC,
such as a build or platform choice, goes straight to an ADR.

`docs/adrs/README.md` and `docs/rfcs/README.md` hold the full contract for each, including frontmatter,
required sections and lifecycle.

### RFC Reference Or Review

Every review goes in `docs/reviews/`, whether it reviews one RFC's change set, the codebase, the test suite
or the documentation. Evidence gathered while building an RFC (a spike, a measurement, a split-out design
note) belongs in `docs/rfcs/refs/`.

The test is whether the document judges work or feeds it. A spike gathered as evidence for RFC-0034 feeds
the RFC, so it is a ref. A code review of RFC-0040's change set judges it, so it is a review, even though it
is about one RFC.

### Living Or Point-In-Time

Documents in `docs/architecture/`, `docs/guides/` and `docs/reference/` are living: they are edited to
stay true, and a stale one is a defect. Documents in `docs/reviews/`, `docs/rfcs/refs/`, the implemented
RFCs, and `docs/architecture/initial-module-design/` are point-in-time: they record what was true when
they were written and are not updated afterwards. The exception is a review's `-status.md` companion, which
tracks what became of the review's recommendations and is living. Point-in-time documents carry a date in
the filename where practical, as `<subject>-YYYYMMDD.md`.

## Documentation Sources Of Truth

| Question                                            | Answered by                                                                                                          |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| What was decided, and what would reopen it          | `docs/adrs/` and its generated `index.md`                                                                            |
| How the system fits together                        | `docs/architecture/` (network, project organisation, and so on)                                                      |
| How each piece gets built                           | `docs/rfcs/` and its generated `index.md`                                                                            |
| How to carry out an operational task                | `docs/guides/`                                                                                                       |
| What a module is                                    | The module's own Haddock header under `packages/*/src/`; there is deliberately no hand-kept module index, it drifted |
| What a domain term means                            | `GLOSSARY.md` at the repository root, the glossary maintained by the domain-modeling skill                           |
| Which refactorings were made or deferred            | `docs/refactoring.log`, appended by the tdd skill; a log, not a document to edit                                     |
| What a config key is, by lookup                     | `docs/reference/configuration.md`                                                                                    |
| Which architecture-review candidates are still open | `docs/reviews/architecture-review-haskell-20260916-status.md`, the living status of the 2026-09-16 Haskell review    |

A decision is written down once, in an ADR. Architecture documents explain mechanism and link to the
register rather than restating decisions. Changing a decision means writing a new ADR, not editing prose
in several places.

## Documentation Generated Indexes

Two indexes are generated from frontmatter and must not be edited by hand:

- `docs/adrs/index.md`, regenerated with `bun run adr:index`
- `docs/rfcs/index.md`, regenerated with `bun run rfc:index`

Run the matching command after adding a record or changing its frontmatter. `make docs` checks both are
current (`bun run check:adr-index` and `check:rfc-index`).
