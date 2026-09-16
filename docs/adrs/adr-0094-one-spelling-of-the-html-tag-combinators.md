---
id: ADR-0094
name: One Spelling Of The HTML Tag Combinators
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0094: One Spelling Of The HTML Tag Combinators

## Context

`MicroHttp.Html` defined every common tag twice: the primitive `x_ = el "x"`
and an unprefixed alias `x = x_`, 23 pairs in all. The interface exported both
spellings, so the module offered ~66 names for ~80 definitions with nothing to
choose between half of them. The starter design
(`docs/architecture/initial-module-design/html.md`) asked for exactly this: it
preferred the unsuffixed helpers, deliberately overlapping Prelude names to
match the blaze-html import pattern, and kept the underscored forms as
compatibility aliases.

That preference never took hold in the code. By the time it was measured,
`Verso/View.hs` used 43 unprefixed against 44 suffixed calls -- the same file
spelling the same element both ways -- and `Verso/Chrome.hs` 5 against 9. The
interface had drifted too: `form` was defined but, alone among its 22 siblings,
never exported. A reader had no rule to apply and no signal from the code, and
the duplication was a standing invitation for the two halves to diverge.

The unprefixed names were also the ones that cost something. `div`, `head` and
`span` shadow Prelude, which is why the module carried
`import Prelude hiding (div, head, span)`; `main` and `title` shadow other
common names. The `x_` forms are the primitives and shadow nothing.

This came out of the 2026-09-16 Haskell architecture review as candidate 7,
rated Speculative. The review's own framing -- "shrink the interface" -- was the
weaker half of the argument; the inconsistency in the callers is the real one.

## Decision

Keep the `x_` tag combinators as the single spelling and drop the 23 unprefixed
aliases from both the implementation and the export list. Callers use the
suffixed form. `import Prelude hiding (...)` is no longer needed in
`MicroHttp.Html` and is now a plain import.

This reverses the starter design's stated preference. That document is a frozen
point-in-time artifact (`docs/README.md`) and is left as written, along with its
other superseded content, such as htmx, removed in RFC-0036; this ADR is the
current rule and supersedes it in practice.

Attribute helpers keep their suffixes where the unsuffixed name would be
awkward or reserved, such as `class_`. That convention is unchanged.

## Consequences

The interface roughly halves, to one obvious name per tag, and new code has a
rule to follow rather than a coin to flip. Nothing about rendering changes:
every alias was a direct synonym, so the emitted bytes are identical, which is
what let the change be verified by the existing golden cases rather than new
ones.

The cost is a one-off edit across the two HTML authoring modules, 55 call sites
in `Verso/View.hs`, `Verso/Chrome.hs` and `HtmlSpec.hs`. Callers written against
the unprefixed spelling, including any outside this tree, no longer compile and
must add the suffix; the fix is mechanical and the compiler names every site.
