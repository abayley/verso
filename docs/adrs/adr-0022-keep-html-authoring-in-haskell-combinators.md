---
id: ADR-0022
name: Keep HTML Authoring in Haskell Combinators
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0022: Keep HTML Authoring in Haskell Combinators

## Context

MicroHs does not support Template Haskell, so compile-time-checked
template systems in the Hamlet/Shakespeare style are unavailable; a template
engine here would be a runtime string parser with runtime failures and a
second escaping discipline. The htmx application style composes many small,
conditional, parameterised fragments, which suits function composition. The
recognised future case for templates is an external designer producing HTML
files with content placeholders, in the Heist or Mustache style; that need
does not exist in the project today.

## Decision

Keep the pure monadic HTML combinators (`MicroHttp.Html`,
ADR-0013) as the canonical and only HTML authoring mechanism. Defer any
template engine until a concrete designer-authored-HTML need appears.

## Consequences

All pages and fragments are authored as combinator values, and
escaping stays centralised in one renderer. If a template engine is added
later, it should parse template files at application start into the existing
`Html` value type, so rendering and escaping remain single-sourced and
templates become a front end to the combinators rather than a parallel
system.
