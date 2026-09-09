---
id: ADR-0083
name: TypeScript Owns Editor Layout Thresholds
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0083: TypeScript Owns Editor Layout Thresholds

> Status: Accepted (2026-08-06).

## Context

The navigation rail threshold was repeated in TypeScript and CSS,
while the metadata pane threshold and its decision based on rail state lived in
the editor host. Changes relied on comments and visual checks. Tests could not
exercise the decision without constructing the browser host.

## Decision

One TypeScript layout module owns the 74rem navigation threshold and
the 93rem metadata pane threshold. The module publishes media query strings
from one threshold table and returns the navigation and metadata layout from
query match state and stored rail collapse state. The editor host retains
browser subscriptions and DOM attribute updates.

The responsive CSS remains handwritten. The editor build checks that the
navigation media query in the stylesheet agrees with the TypeScript threshold
table, and comments cannot satisfy the check. Generating a CSS fragment for
one query would add another build output and split the responsive rules across
authored and generated files. The build check detects threshold drift while
keeping the complete layout rules in the stylesheet.

## Consequences

Threshold changes require an intentional table and stylesheet
change, and the build rejects disagreement. The pure layout decision has a
small truth table that unit tests can cover without browser width conversion.
The 70rem presentation controls, 52rem and 44rem container queries, 48rem split
view, and 33rem small screen rules remain outside this decision.
