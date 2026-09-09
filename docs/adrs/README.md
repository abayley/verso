# MicroHttp Architectural Decision Record Process

This directory is the decision register for the project. One file records one decision, and the file is
the source of truth for that decision. Anything derived from a decision, including design documents and
the architecture overview, takes the decision from here rather than restating it.

## ADR Directory Contract

- ADR working directory: `docs/adrs`
- File naming: `adr-<4-digit-id>-<short-kebab-name>.md` (example: `adr-0072-concordance-search-engine-behind-a-project-c-shim.md`)
- Template source: `docs/adrs/adr-template.md`
- Canonical index: `docs/adrs/index.md` (generated from ADR frontmatter and the `## Decision` section)
- ADR frontmatter is the source of truth. The index is a generated view, written by `bun run adr:index`.
- ADRs are not moved between directories as their status changes. A superseded ADR stays where it is.

## ADR Required Metadata

Every ADR starts with YAML frontmatter:

```yaml
---
id: ADR-XXXX
name: <short decision name>
status: Accepted
owners:
    - <team or person>
supersedes: []
superseded_by: null
related_rfcs: []
---
```

Rules:

- `id` is unique, assigned in creation order, and never reused or renumbered.
- `status` must be one of: `Proposed`, `Accepted`, `Superseded`, `Deprecated`.
- `supersedes` and `superseded_by` must be kept accurate in both directions.
- `related_rfcs` lists RFC IDs that specify or implement the decision, and is empty when no RFC owns it.
- `created` and `updated` dates are recommended on new ADRs. They are omitted on the records split from the
  original single-file register, where the dates were not recorded per decision.

## ADR Required Sections

Each ADR contains these headings, in this order. `## Consequences` is optional; `## Why` and
`## Reopens when` are recommended for new decisions and were not retrofitted onto the migrated register
(see the migration note below).

1. `## Context`
2. `## Decision`
3. `## Why`
4. `## Reopens when`
5. `## Consequences`

The `## Reopens when` section is what keeps the register honest. It names the condition that would
invalidate the decision, so a decision can be checked against reality rather than only remembered.
`Never` is a valid entry when the reasoning is structural.

## ADR Lifecycle

1. Proposed: the decision is drafted but not settled.
2. Accepted: the decision is in force.
3. Superseded: replaced by a newer ADR. Link both directions and leave the file in place.
4. Deprecated: no longer in force and not replaced, because the thing it decided no longer exists.

ADRs are append-only. A change of mind is a new ADR that supersedes the old one, never an edit to the
`## Decision` section of the existing file. Correcting a typo, adding evidence, or clarifying wording is
an edit; changing what was decided is a new ADR.

When an ADR moves to `Superseded`, update all of these together:

- the superseded ADR's `status` and `superseded_by`
- the superseding ADR's `supersedes`
- any document that cited the old decision
- run `bun run adr:index`

## ADR and RFC Boundary

An RFC proposes how to build something and is the venue for review. An ADR records that a decision was
made and why. The two have different lifetimes: an RFC is finished once its work is implemented and moves
to `docs/rfcs/implemented/`, while an ADR stays in force until something supersedes it.

- A decision reached inside an RFC gets an ADR when it is load-bearing beyond that RFC's own
  implementation. Set `related_rfcs` on the ADR, and let the RFC carry the option analysis rather than
  repeating it in the ADR.
- A decision reached outside any RFC, such as a build, tooling, or platform choice, goes straight to an
  ADR with an empty `related_rfcs`.
- Not every RFC choice needs an ADR. If a choice only shapes the internals of one RFC's implementation and
  nothing outside it would need to know, leave it in the RFC.

`docs/rfcs/README.md` holds the RFC contract.

## ADR Markdown Style

All ADR tables use aligned Markdown table formatting, matching the RFC convention. Prose wraps at the
repository line length.

## Migration Note

ADR-0001 through ADR-0085 were split out of the former single-file register `docs/decision-register.md`.
The split is faithful: it preserves each decision's Context, Decision, and Consequences verbatim, pads the
three-digit ids to four digits, and derives frontmatter from the original Status line. The original Status
line is kept as a `> Status:` note where it carried more than a bare status word (an RFC reference, a date,
a supersession, or an amendment). The `## Why` and `## Reopens when` sections and per-decision dates were
not backfilled, because inventing that content would misrepresent what was recorded. New ADRs follow the
full template.
