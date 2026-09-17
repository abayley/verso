---
id: ADR-0095
name: Percent Decoding Follows The WHATWG Recovery Rule
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
created: 2026-09-17
updated: 2026-09-17
related_rfcs: [RFC-0042, RFC-0043]
---

# ADR-0095: Percent Decoding Follows The WHATWG Recovery Rule

## Context

Percent-decoding (RFC 3986 section 2.1) was implemented four times: the
streaming byte decoder in `MicroHttp.Form`, a `String` decoder in
`MicroHttp.Http` reached from `pathSegments` and `parseQuery`, a copy in the
application at `Verso.Attachment.percentDecode`, and the oracle in
`test/unit/MicroHttp/FormSpec.hs`. Each carried its own hex-digit helper.

RFC 3986 gives the grammar for an escape but no rule for input that breaks it,
and the copies had settled on two different answers. On a `%` not followed by
two hexadecimal digits, the three framework-side copies emitted all three bytes
and advanced past them; `Verso.Attachment` emitted the `%` alone and advanced
one byte. The difference is only visible when a malformed escape is followed by
a valid one:

| input    | framework | Attachment |
| -------- | --------- | ---------- |
| `%%41`   | `%%41`    | `%A`       |
| `%4%41`  | `%4%41`   | `%4A`      |
| `%zz`    | `%zz`     | `%zz`      |

The WHATWG URL standard's percent-decode algorithm is the second: append the
`0x25` byte and continue with the next byte. Browsers do that, so the framework
under-decoded relative to every client that would talk to it. Nothing recorded a
decision: RFC-0042 adopted the skip-three behaviour for the streaming decoder
explicitly to match "the old decoder", which had it for no stated reason.

This came out of the 2026-09-16 architecture review as the second half of
candidate 7's successor, candidate 5 ("Form and Http share one decoder"), rated
*Worth exploring*.

## Decision

`MicroHttp.Percent` is the one percent-decoder. It works on bytes, because the
bytes an escape spells are UTF-8 that a caller reads as text with
`Utf8.decodeUtf8` when it wants characters (RFC-0043), and it follows the WHATWG
recovery rule: a `%` that does not begin a valid escape is emitted as itself and
the scan advances one byte. Decoding never rescans its own output, so `%2541`
stays `%41`.

`Form.decodeFormValueI` and `Http.decode` both call it, and
`Verso.Attachment.percentDecode` is `Http.decodePathSegment`. `FormSpec`'s
oracle keeps a separate implementation, because an oracle written in terms of
the code it checks proves nothing, but it now states the WHATWG rule.

`Http.decode` keeps its `String` signature and packs and unpacks around the byte
decoder. That `String` carries bytes, not characters: it comes from
`Char8.unpack` of the request line, so `Char8.pack` is its exact inverse and a
character above `U+00FF` is outside the contract.

## Consequences

A malformed escape followed by a valid one now decodes the way a browser sends
it. This is a behaviour change to `decodePathSegment` and `decodeFormValue`,
which are exported, and to every request's path segments and query values; it
only affects input that was already invalid, and it decodes more, never less.

One rule in one place, so the next edit cannot half-land, and the drift that
made the four copies disagree is gone by construction rather than by test.

The decoder makes one pass where both previous versions made two (a scan for the
carry, then the decode). That pays back most of the new rule's cost but not all:
telling advance-one from skip-three needs the hex tests at each `%` that
skipping blindly avoided. Measured with `make bench-percent-decode` on a
urlencoded body, the block decoder goes from 0.64 to 0.81 ms per 22800 bytes,
1.27x. The `String` wrapper's pack and unpack cost 0.09 to 0.43 microseconds per
path segment, so a request pays a few microseconds across its segments and query
values; segments are short and this is the shape that matters. Removing even
that means carrying the request target as bytes instead of unpacking it into a
`String` in `parseRequestHead`, which is a larger change and is not done here.

### Where the value ends

A `%` with fewer than two bytes after it means different things in the middle of
a stream and at the end of a value: in a stream it is carried, because the next
block may complete the escape, but at the end nothing can complete it, so it is
malformed and the recovery rule applies to it like any other `%`. The walk takes
that as a parameter rather than leaving the caller to flush a carry verbatim.

Flushing verbatim is what the streaming decoder did before, and it was already
subtly wrong for the old rule's own reasons; unifying spread it to the `String`
decoder, which had been right, so `"a%+"` decoded to `"a%+"` instead of `"a% "`.
The hand-picked cases missed it because none ended in `%+`. The decoder is now
checked against the oracle over every string of up to four bytes drawn from
`%`, `4`, `z`, `+` and `a`, at every block size -- 780 inputs -- so shapes nobody
thought to write down are covered.
