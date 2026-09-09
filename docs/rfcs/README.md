# MicroHttp RFC Process

This directory is the canonical source for how each piece of the project gets built. An RFC proposes a
technical solution and is the venue for review; a decision it reaches that is load-bearing beyond its own
implementation becomes an ADR under `docs/adrs/`.

## Directory Contract

- RFC working directory: `docs/rfcs`
- Active RFC location: `docs/rfcs/` for `Draft`, `Accepted`, `Rejected`, and `Superseded`
- Implemented RFC location: `docs/rfcs/implemented/`
- RFC supporting material location: `docs/rfcs/refs/`, for reviews, evidence, and split-out design notes
  that exist to support a specific RFC. A review of the codebase or the documentation as a whole is not
  RFC supporting material and belongs in `docs/reviews/`.
- File naming: `rfc-<4-digit-id>-<short-kebab-title>.md` (example: `rfc-0034-hybrid-search.md`)
- Follow-on file naming: `rfc-<4-digit-id><letter>-<short-kebab-title>.md` for narrow adjunct RFCs that
  belong beside an existing RFC.
- Canonical index: `docs/rfcs/index.md` (generated from RFC frontmatter by `bun run rfc:index`)
- RFC frontmatter and RFC file placement are the source of truth. The index is a generated view.
- Implemented RFCs do not keep a duplicate copy in the root RFC directory.

## Required Metadata

Every RFC starts with YAML frontmatter:

```yaml
---
id: RFC-XXXX
name: <short name>
status: Draft
owners:
    - <team or person>
created: YYYY-MM-DD
updated: YYYY-MM-DD
supersedes: []
superseded_by: null
---
```

Rules:

- `id` is unique and never reused. Use `RFC-0014B`-style suffix ids only for narrow follow-on RFCs that
  should sort beside their base RFC.
- `status` must be one of: `Draft`, `In Progress`, `Accepted`, `Implemented`, `Rejected`, `Superseded`,
  `Evergreen`.
- `supersedes` and `superseded_by` must be kept accurate when RFC relationships change.

Optional relationship fields: `parent_rfc`, `child_rfcs`, `design_contract_rfcs`, and `related_rfcs`.

## Conventional Sections

The template gives an RFC this section shape, and the existing RFCs follow it:

1. `## Summary`
2. `## Context`
3. `## Goals`
4. `## Non-Goals`
5. `## Proposal`
6. `## Alternatives Considered`
7. `## Security Impact`
8. `## Reliability Impact`
9. `## Compatibility Impact`
10. `## Testing and Quality Gates`
11. `## Rollout Plan`
12. `## Open Questions`

These are a convention, not a gate. Use the shape as a checklist so a reviewer knows where to look, and
drop or merge a section a particular RFC does not need. The index generator checks only frontmatter,
status, and directory placement; it does not enforce sections or any end-to-end test declaration.

## Lifecycle

1. Draft: author creates the RFC from the template.
2. Accepted: scope and contract approved; implementation may start.
3. Implemented: implementation complete and validated; the file moves to `docs/rfcs/implemented/`.
4. Rejected: explicitly not proceeding.
5. Superseded: replaced by a newer RFC; link both directions.
6. Evergreen: an intentionally living contract document.

When an RFC moves to `Implemented`, update all of these together:

- RFC frontmatter status
- the RFC file path under `docs/rfcs/implemented/`
- any repo references that still point at the root RFC path
- run `bun run rfc:index`

## RFC and ADR Boundary

An RFC proposes how to build something and is the venue for review. An ADR states that a decision was made
and why, and stays in force until something supersedes it. A load-bearing choice reached inside an RFC gets
an ADR under `docs/adrs/`, with the ADR's `related_rfcs` pointing back at the RFC and the RFC's
`## Alternatives Considered` section carrying the option analysis. A choice that only shapes one RFC's own
implementation stays in the RFC. `docs/adrs/README.md` holds the ADR contract.

## RFC Markdown Style

All RFC tables use aligned Markdown table formatting. Aligned tables keep RFC progress trackers and rule
inventories readable during review.
