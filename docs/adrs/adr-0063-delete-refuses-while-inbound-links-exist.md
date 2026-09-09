---
id: ADR-0063
name: Delete Refuses While Inbound Links Exist
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0027]
---

# ADR-0063: Delete Refuses While Inbound Links Exist

> Status: Accepted (RFC-0027). Scope: realised in phase 4 (delete); recorded here with the move contract.

## Context

the served tree is gitignored, so a delete that drops pages other pages
link to would leave dangling links with no git undo. The target's own parent
`index.md` lists it, so that listing entry must not itself count as a blocking
reference (otherwise nothing would be deletable).

## Decision

a delete first removes the target's entry from its parent `index.md`
listing (the same membership reconciliation a move does), then refuses if any
**other** page still links to the target (for a section, any page outside the
subtree), returning the referrer list so the author resolves them first. Otherwise
the target is routed to RFC-0028's trash rather than destroyed.

## Consequences

the tree stays link-clean and deletes are reversible by the author
(resolve the referrers, or restore from trash). Full content history awaits the
versioning store.
