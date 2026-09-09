---
id: ADR-0077
name: Two Visual Themes -- Shadcn Default, Studio as Interaction Model
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0035]
---

# ADR-0077: Two Visual Themes -- Shadcn Default, Studio as Interaction Model

> Status: Accepted (RFC-0035, grill decision 2026-07-08).

## Context

Six themes predated the Basecoat migration (Paper, Aurora,
Blueprint, Workbench, Studio, and the new Shadcn). Each surviving theme
must be re-expressed over Basecoat's anatomy, and the shadcn look was
chosen as the design language; only themes actually used earn that
migration work.

## Decision

Keep two: `shadcn` is the default -- its oklch tokens are the
:root defaults, dark keyed on Basecoat's `.dark` class -- and `studio`
is purely an interaction-model switch (bubble toolbar + slash menu
instead of the persistent command bar) with the same look. Paper,
Aurora, Blueprint, and Workbench retire, including Workbench's
open-in-split preset. Retired or unknown stored/configured theme names
fall back to `shadcn`.

## Consequences

The theme dropdown lists two entries; the mockups under
docs/mockups/ remain the source for future themes, which return as
shadcn token overrides plus an un-layered override sheet (Basecoat's
CSS is entirely inside @layer, so plain theme sheets win the cascade)
plus structural CSS -- see RFC-0035's theme section. Aurora's frosted
look and Workbench's IDE frame can be resurrected from git history if
missed.
