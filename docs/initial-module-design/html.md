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

instance IsString (Html ())

html :: [(Text, Text)] -> Html () -> Html ()
head :: [(Text, Text)] -> Html () -> Html ()
body :: [(Text, Text)] -> Html () -> Html ()
h1 :: [(Text, Text)] -> Html () -> Html ()
p :: [(Text, Text)] -> Html () -> Html ()
```

The preferred call style is qualified and close to `blaze-html`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

import qualified MicroHttp.Html as H

page :: H.Html ()
page =
  H.html [H.lang "en"] $ do
    H.head [] $
      H.title [] "MicroHttp"
    H.body [] $
      H.main [] $ do
        H.h1 [] "Hello"
        H.p [] "Rendered as escaped text"
```

## HTML Module Builder Decision

Use the local builder for the first implementation. The active MicroHs package
path did not provide `xhtml` or `lucid` during the spike run, and the local
builder handles htmx/custom-element markup directly.

External combinator libraries remain follow-up package-port checks.

## HTML Module Naming Decision

Prefer unsuffixed element helpers such as `html`, `head`, `body`, `h1`, and `p`
when importing the module qualified. These names intentionally overlap with a few
Prelude names, matching the usual blaze-style import pattern.

Keep underscored helpers such as `html_`, `head_`, and `p_` as compatibility
aliases. Attribute helpers can still use suffixes where the unsuffixed name would
be awkward or reserved, such as `class_`.

## HTML Module Text Decision

Support `OverloadedStrings` through `IsString (Html ())`, with string literals
rendered through the same escaping path as `text`. Use `rawTrusted` only for
already-sanitised markup.
