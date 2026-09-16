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

The rule extends to `el`, which is the other way to spell a tag. Where a
combinator exists, callers use it; `el "x"` is for tags that have none, such as
the table elements and `svg`. Leaving both in play for the same tag would put
back at the call site the coin-flip this ADR removes at the library boundary,
so the 15 `el` calls in `Verso/View.hs` naming a tag that had a combinator were
converted with the aliases.

### The two escapers are kept separate, and tested instead

The review that prompted this asked for a second thing: "route `escapeChars`
through `escapeBlockBytes`", so that text escaping had "one escaper, so one
escaping bug". That is declined for now, and the two paths are pinned against
each other by test instead (`test/unit/MicroHttp/HtmlSpec.hs`, the agreement
cases and the escape-set surveys).

`escapeChars` is pure, `String -> Builder`; `escapeBlockBytes` is
`ByteString -> IO ByteString`, in `IO` because it allocates and writes an output
buffer. Merging them means calling the second from the first under
`unsafePerformIO`. ADR-0086 permits `unsafePerformIO` only for a foreign call
that is read-only over a private marshalled copy, and explicitly not for one
that "writes, allocates observably, or touches shared state", so the merge does
not fit the sanctioned shape as written. `Html.hs` already records that reading
at the definition.

The argument the other way is real and worth stating, so it is not relitigated
from scratch. ADR-0086's own rationale names "two implementations that must be
kept byte-identical" as the failure mode a single shared core exists to prevent
-- which is exactly the position of these two escapers -- and the buffer
`escapeBlockBytes` writes is freshly allocated and unaliased, not shared state,
so the call is still a pure function of its argument's bytes.

What settles it for now is that the merge is an architectural change with an
unmeasured cost: a foreign call is ~2-3us, and `escapeChars` runs per text node
and per attribute value, so a page with hundreds of nodes pays hundreds of
calls. It might still win, because the current implementation does a
`concatMap` over a `String`, the allocation pattern mhs is worst at. Nobody has
measured it. Doing it properly means a benchmark and an amendment to ADR-0086,
which is more than this change is worth; the tests remove the silent-drift risk
that made it urgent.

## Consequences

The interface narrows from 66 exported names to 44, one per tag, and new code
has a rule to follow rather than a coin to flip. The review that prompted this
sketched an interface of ~30; that is not reached, because only the tag aliases
were dropped and no other narrowing was attempted. Nothing about rendering changes:
every alias was a direct synonym, so the emitted bytes are identical, which is
what let the change be verified by the existing golden cases rather than new
ones.

The cost is a one-off edit across the two HTML authoring modules: 55 alias call
sites in `Verso/View.hs`, `Verso/Chrome.hs` and `HtmlSpec.hs`, plus the 15 `el`
calls above. Callers written against
the unprefixed spelling, including any outside this tree, no longer compile and
must add the suffix; the fix is mechanical and the compiler names every site.
