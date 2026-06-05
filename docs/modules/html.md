# HTML Module Design

## HTML Module Purpose

`MicroHttp.Html` renders server-side HTML and htmx fragments through a pure
monadic builder.

## HTML Module Responsibilities

- Provide pure `do`-notation rendering.
- Escape text nodes.
- Escape attribute values.
- Support arbitrary attributes.
- Support custom elements.
- Provide helpers for common tags and htmx attributes.
- Expose an explicit `rawTrusted` escape hatch.

## HTML Module Non-Responsibilities

- HTTP response serialisation.
- Template file loading.
- Client-side web component implementation.
- HTML validation.

## HTML Module Public Interface Sketch

```haskell
newtype Html a

type Fragment = Html ()

renderHtml :: Html a -> Builder
text :: Text -> Html ()
rawTrusted :: Builder -> Html ()
el :: Text -> [(Text, Text)] -> Html () -> Html ()
voidEl :: Text -> [(Text, Text)] -> Html ()
custom :: Text -> [(Text, Text)] -> Html () -> Html ()
```

## HTML Module Design Decision

Use the local builder for the first implementation. The active MicroHs package
path did not provide `xhtml` or `lucid` during the spike run, and the local
builder handles htmx/custom-element markup directly.

External combinator libraries remain follow-up package-port checks.
