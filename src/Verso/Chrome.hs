{- | Basecoat chrome helpers (RFC-0035).

Interactive chrome markup is generated ONLY through this module: call sites
state semantic intent ('ButtonIntent'), and this module maps intent to
Basecoat's class\/@data-variant@\/@data-size@ vocabulary and owns the ARIA
wiring that Basecoat's runtime keys on. Incomplete wiring makes the runtime
skip a component silently, so the id discipline here (trigger\/popover\/menu
derived from one base id) is load-bearing, not cosmetic. The TypeScript
mirror for Lit templates is @src/Verso/Editor/chrome.ts@.
-}
module Verso.Chrome (
    ButtonIntent (..),
    chromeButton,
    chromeSubmitButton,
    chromeDropdown,
    chromeIcon,
    chromeTabs,
    tooltipAttrs,
    tooltipAttrsAt,
) where

import qualified MicroHttp.Html as Html

{- | What a control means, not what it looks like. The mapping to Basecoat
variants lives in 'intentAttrs' alone; restyling a class of controls is a
change here, never a call-site sweep.
-}
data ButtonIntent
    = -- | The one emphasised action on a surface (Publish, Save).
      PrimaryAction
    | -- | Everyday chrome: quiet until hovered (most controls).
      QuietControl
    | -- | Secondary action that needs a visible boundary (Cancel).
      OutlineControl
    | -- | Icon-only square control (toolbar and header actions).
      IconControl

-- | The Basecoat attributes for an intent; the only variant vocabulary site.
intentAttrs :: ButtonIntent -> [(String, String)]
intentAttrs intent =
    case intent of
        PrimaryAction -> [Html.class_ "btn", Html.attr "data-size" "sm"]
        QuietControl -> [Html.class_ "btn", Html.attr "data-variant" "ghost", Html.attr "data-size" "sm"]
        OutlineControl -> [Html.class_ "btn", Html.attr "data-variant" "outline", Html.attr "data-size" "sm"]
        IconControl -> [Html.class_ "btn", Html.attr "data-variant" "ghost", Html.attr "data-size" "icon-sm"]

-- | A non-submitting chrome button; extra attributes follow the intent's.
chromeButton :: ButtonIntent -> [(String, String)] -> Html.Html () -> Html.Html ()
chromeButton intent extras = Html.button_ (Html.attr "type" "button" : intentAttrs intent ++ extras)

-- | A form-submitting chrome button (Restore, no-script Save).
chromeSubmitButton :: ButtonIntent -> [(String, String)] -> Html.Html () -> Html.Html ()
chromeSubmitButton intent extras = Html.button_ (Html.attr "type" "submit" : intentAttrs intent ++ extras)

{- | An inline icon referencing the external Lucide sprite
(@static\/editor\/icons.svg@, symbol ids @i-\<name\>@). Stroke styling is
inherited from the @chrome-icon@ class, which also sizes it.
-}
chromeIcon :: String -> Html.Html ()
chromeIcon name =
    Html.el "svg" [Html.class_ "chrome-icon", Html.attr "aria-hidden" "true"] $
        Html.el "use" [Html.attr "href" ("/static/editor/icons.svg#i-" ++ name)] (return ())

-- | A CSS-only Basecoat tooltip, default placement (top centre).
tooltipAttrs :: String -> [(String, String)]
tooltipAttrs label = [Html.attr "data-tooltip" label]

{- | A tooltip with explicit placement. Required near viewport edges: the
tooltip pseudo-element occupies layout, and a centred one on an edge control
widens the page (phantom scrollbars -- spike finding).
-}
tooltipAttrsAt :: String -> String -> String -> [(String, String)]
tooltipAttrsAt label side align =
    [Html.attr "data-tooltip" label, Html.attr "data-side" side, Html.attr "data-align" align]

{- | A Basecoat dropdown menu: trigger, popover, and menu of (value, label)
items, with the full id\/ARIA wiring derived from one base id. Items render
as real buttons carrying @data-value@; selection handling reads the value
from click events on @[role=menuitem]@.
-}
chromeDropdown :: String -> ButtonIntent -> Html.Html () -> [(String, String)] -> Html.Html ()
chromeDropdown ident intent triggerContent items =
    Html.div [Html.class_ "dropdown-menu", Html.attr "id" ident] $ do
        Html.button_
            ( [Html.attr "type" "button", Html.attr "id" (ident ++ "-trigger")]
                ++ intentAttrs intent
                ++ [ Html.attr "aria-haspopup" "menu"
                   , Html.attr "aria-controls" (ident ++ "-menu")
                   , Html.attr "aria-expanded" "false"
                   ]
            )
            triggerContent
        Html.div [Html.attr "id" (ident ++ "-popover"), Html.attr "data-popover" "", Html.attr "aria-hidden" "true"] $
            Html.div [Html.attr "role" "menu", Html.attr "id" (ident ++ "-menu"), Html.attr "aria-labelledby" (ident ++ "-trigger")] $
                mapM_ menuItem items
  where
    menuItem (value, label) =
        Html.button_
            [Html.attr "type" "button", Html.attr "role" "menuitem", Html.attr "data-value" value]
            (Html.text label)

{- | A Basecoat line-variant tab strip of (value, label, selected) entries --
the underlined text tabs the mode and width controls use. Selection handling
reads @data-value@ from click events on @[role=tab]@.
-}
chromeTabs :: String -> [(String, String, Bool)] -> Html.Html ()
chromeTabs ident entries =
    Html.div [Html.class_ "tabs", Html.attr "id" ident] $
        Html.nav [Html.attr "role" "tablist", Html.attr "aria-orientation" "horizontal", Html.attr "data-variant" "line"] $
            mapM_ tab entries
  where
    tab (value, label, selected) =
        Html.button_
            [ Html.attr "type" "button"
            , Html.attr "role" "tab"
            , Html.attr "data-value" value
            , Html.attr "aria-selected" (if selected then "true" else "false")
            , Html.attr "tabindex" (if selected then "0" else "-1")
            ]
            (Html.text label)
