{- | Page rendering extracted from the request handlers (RFC-0035).

App.hs keeps routing and handlers; this module owns page shells, whole-page
views, and the theme registry they share. Appearance diffs land here (and in
"Verso.Chrome" for controls), never in handler code. The extraction runs
through the RFC's phases; the editor page itself moves as its chrome
migrates.
-}
module Verso.View (
    chromeHeadAssets,
    diffBody,
    diffPage,
    editorThemeBootstrapScript,
    excerptOf,
    historyPage,
    knownEditorThemes,
    safeEditorTheme,
    searchPage,
    versionPageShell,
) where

import qualified Concordance.Store as Store
import qualified Control.Monad as Monad
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Html as Html
import qualified Verso.Chrome as Chrome
import qualified Verso.Git as Git

{- | The visual themes the editor implements (RFC-0035): the default shadcn
look, and Studio, which keeps the same look but swaps the persistent command
bar for the bubble toolbar and slash menu. The page default and the pre-paint
bootstrap validate against this set, so an unknown configured or stored value
(including retired theme names) falls back to the default.
-}
knownEditorThemes :: [String]
knownEditorThemes = ["shadcn", "studio"]

-- | Validates a configured default theme name, falling back to @shadcn@.
safeEditorTheme :: String -> String
safeEditorTheme theme
    | theme `elem` knownEditorThemes = theme
    | otherwise = "shadcn"

{- | A JavaScript array literal of the given strings, e.g. @['a','b']@. The
theme names are simple identifiers, so single-quoting without escaping is safe;
this keeps the bootstrap allowlist derived from 'knownEditorThemes' rather than
duplicated. (The dropdown's parallel list lives in the editor TypeScript.)
-}
jsStringArray :: [String] -> String
jsStringArray items =
    "[" ++ List.intercalate "," (map (\item -> "'" ++ item ++ "'") items) ++ "]"

{- | An inline, pre-paint script that applies the visitor's stored editor
preferences before the body renders, so a saved theme or colour scheme does not
flash the page default. It sets the theme attribute only from a fixed allowlist,
so a tampered stored value cannot inject an attribute payload.
-}
editorThemeBootstrapScript :: String
editorThemeBootstrapScript =
    "<script>(function(){try{"
        ++ "var K="
        ++ jsStringArray knownEditorThemes
        ++ ";var r=document.documentElement;"
        ++ "var t=localStorage.getItem('editor-theme');"
        ++ "if(t&&K.indexOf(t)>=0){r.setAttribute('data-editor-theme',t);}"
        ++ "var s=localStorage.getItem('editor-color-scheme');"
        -- Resolve dark/light/system exactly as the editor element's resolvedEditorTheme does (RFC-0032):
        -- only the literal 'dark'/'light' are explicit; ANY other value (unset, or the stored
        -- 'match-system') follows the OS preference. Applied here so every page -- editor, reader, and the
        -- standalone history/diff views -- paints consistently. (Earlier this only matched 'system', so the
        -- stored 'match-system' fell through to light.)
        ++ "var d=s==='dark'||(s!=='light'&&window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches);"
        ++ "r.classList.toggle('wa-dark',d);r.classList.toggle('wa-light',!d);r.classList.toggle('dark',d);"
        ++ "}catch(e){}})();</script>"

{- | The stylesheet and script tags shared by every full page: the vendored
Geist font and Basecoat chrome bundle (RFC-0035), the Web Awesome styles
(until Phase 5 removes them), and the app stylesheet. Order matters: Basecoat
loads before the app stylesheet so un-layered app rules win the cascade.
-}
chromeHeadAssets :: Html.Html ()
chromeHeadAssets = do
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/geist.css\">"
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/basecoat.css\">"
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/webawesome.css\">"
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
    Html.rawTrusted "<script src=\"/static/editor/basecoat.js\" defer></script>"
    Html.rawTrusted chromeInitScript

{- | Re-scans for uninitialised Basecoat components after every DOM-producing
event the runtime cannot observe itself: initial load and htmx swaps (the
spike's integration contract; Lit elements call initAll from their own
updated() hooks). initAll is idempotent, so over-calling is harmless.
-}
chromeInitScript :: String
chromeInitScript =
    "<script>(function(){function i(){window.basecoat&&window.basecoat.initAll();}"
        ++ "document.addEventListener('DOMContentLoaded',i);"
        ++ "document.addEventListener('htmx:afterSwap',i);})()</script>"

{- | The full-page shell shared by the history, diff, and search views. It
reuses the editor page's theming (the @wa-@ palette classes, the
@data-editor-theme@ default, the theme-bootstrap script, and the shared head
assets) so these pages match the editor\/reader look, and loads the editor
bundle so the components used by the theme controls register and render
exactly as in the editor (RFC-0032). The @\<markdown-editor\>@ element the
bundle also defines is simply unused on these pages.
-}
versionPageShell :: String -> String -> Html.Html () -> Html.Html ()
versionPageShell themeDefault pageTitle bodyContent =
    Html.html [Html.lang "en", Html.class_ "wa-theme-default wa-palette-default wa-brand-blue", Html.attr "data-editor-theme" (safeEditorTheme themeDefault)] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.rawTrusted editorThemeBootstrapScript
            Html.title [] (Html.text pageTitle)
            chromeHeadAssets
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\"></script>"
        Html.body [Html.class_ "markdown-editor-page verso-version-page"] $
            Html.main [] bodyContent

{- | The search page: the query form and, when search ran, its results.
'Nothing' means search is not enabled on this server.
-}
searchPage :: String -> String -> Maybe ([Store.Hit], Int) -> Html.Html ()
searchPage themeDefault query outcome =
    versionPageShell themeDefault "Search" $ do
        versionControls themeDefault
        Html.el "h1" [] (Html.text "Search")
        Html.p [Html.class_ "verso-version-back"] (Html.a [Html.href "/documents/"] (Html.text "Back to the wiki"))
        Html.el "form" [Html.attr "method" "get", Html.attr "action" "/search", Html.class_ "verso-search-form"] $ do
            Html.input [Html.class_ "input", Html.attr "type" "search", Html.attr "name" "q", Html.attr "value" query, Html.attr "placeholder" "Search the wiki", Html.attr "autofocus" ""]
            Chrome.chromeSubmitButton Chrome.OutlineControl [] (Html.text "Search")
        case outcome of
            Nothing ->
                Html.p [] (Html.text "Search is not enabled on this server (see search_enabled and make search-shim).")
            Just (hits, depth) -> do
                Monad.when (depth > 0) $
                    Html.p [Html.class_ "verso-search-pending"] (Html.text ("Indexing in progress: " ++ show depth ++ " page(s) pending; results may be incomplete."))
                Monad.unless (null query) $
                    if null hits
                        then Html.p [] (Html.text "No results.")
                        else Html.el "ol" [Html.class_ "verso-search-results"] (mapM_ searchResult hits)

-- | One search result: the page (and section) linked, with a text excerpt.
searchResult :: Store.Hit -> Html.Html ()
searchResult hit =
    Html.el "li" [] $ do
        Html.p [Html.class_ "verso-search-hit"] $ do
            Html.a [Html.href ("/documents/" ++ Store.hitPage hit)] (Html.text (Store.hitPage hit))
            Monad.unless (null (Store.hitAnchor hit)) $
                Html.el "span" [Html.class_ "verso-search-anchor"] (Html.text (" > " ++ Store.hitAnchor hit))
        Html.p [Html.class_ "verso-search-excerpt"] (Html.text (excerptOf (Store.hitText hit)))

{- | A result's one-line excerpt: the chunk text past its context line and
its own heading line, flattened.
-}
excerptOf :: String -> String
excerptOf text =
    let bodyLines = drop 1 (lines text)
        prose = dropWhile (\l -> null (trimSpace l) || isHeadingLine l) bodyLines
        flat = unwords prose
     in take 240 flat
  where
    isHeadingLine l = case span (== '#') l of
        (hashes, ' ' : _) -> not (null hashes) && length hashes <= 6
        _ -> False

-- | Leading and trailing ASCII whitespace stripped.
trimSpace :: String -> String
trimSpace = f . f
  where
    f = reverse . dropWhile (`elem` " \t\r\n")

{- | Renders the revision-history page: theme\/appearance controls, a
fixed-height scrollable table of revisions (each timestamp links to that
revision in the read-only view, with a per-row Restore), and a diff pane below
that appears automatically, side-by-side, once two revisions are selected.
-}
historyPage :: String -> String -> String -> [Git.Revision] -> Html.Html ()
historyPage themeDefault title path revs =
    versionPageShell themeDefault ("History: " ++ title) $ do
        versionControls themeDefault
        Html.el "h1" [] (Html.text "Revision history")
        Html.p [Html.class_ "verso-version-back"] (Html.a [Html.href ("/documents/" ++ path)] (Html.text ("Back to " ++ path)))
        if null revs
            then Html.p [] (Html.text "No revisions yet.")
            else do
                Html.div [Html.class_ "verso-history-scroll"] $
                    Html.el "table" [Html.class_ "verso-history"] $ do
                        Html.el "thead" [] (Html.el "tr" [] (mapM_ (Html.el "th" [] . Html.text) ["", "When", "Who", "Message", ""]))
                        Html.el "tbody" [] (mapM_ (revisionRow path) revs)
                Html.p [Html.attr "id" "verso-diff-hint", Html.class_ "verso-diff-hint"] (Html.text "Select two revisions to see a side-by-side diff.")
                Html.div [Html.attr "id" "verso-diff-pane", Html.class_ "verso-diff-pane", Html.attr "data-path" path, Html.attr "hidden" ""] (pure ())
                Html.rawTrusted historyScript

{- | The theme and appearance (light\/dark\/match-system) controls on the version
pages, rendered with the same Basecoat chrome and classes as the editor (a
dropdown menu for the visual theme and a joined group of icon buttons for the
colour scheme). 'historyScript' wires them to the same @localStorage@ keys the
editor uses, so a choice here carries over to the editor and back.
@themeDefault@ sets the initial dropdown label.
-}
versionControls :: String -> Html.Html ()
versionControls themeDefault =
    Html.div [Html.class_ "markdown-editor__toolbar markdown-editor__toolbar--top verso-version-toolbar"] $
        Html.div [Html.class_ "markdown-editor__toolbar-controls"] $
            Html.div [Html.class_ "markdown-editor__appearance"] $ do
                themeDropdown
                schemeGroup
  where
    themeDropdown =
        Chrome.chromeDropdown
            "verso-theme-menu"
            Chrome.QuietControl
            ( do
                Html.el "span" [Html.attr "id" "verso-theme-trigger"] (Html.text (themeLabelFor (safeEditorTheme themeDefault)))
                Chrome.chromeIcon "chevron-down"
            )
            visualThemeOptions
    schemeGroup =
        Html.div [Html.class_ "chrome-segment-joined", Html.attr "id" "verso-scheme-group", Html.attr "role" "radiogroup", Html.attr "aria-label" "Editor colour theme"] $ do
            schemeButton "light" "Light" "sun"
            schemeButton "dark" "Dark" "moon"
            schemeButton "match-system" "Match system" "monitor"
    schemeButton value label icon =
        Chrome.chromeButton
            Chrome.IconControl
            ([Html.attr "data-scheme" value, Html.attr "role" "radio", Html.attr "aria-checked" "false", Html.attr "aria-label" label] ++ Chrome.tooltipAttrsAt label "bottom" "end")
            (Chrome.chromeIcon icon)
    visualThemeOptions = [("shadcn", "Shadcn"), ("studio", "Studio")]
    themeLabelFor t = Maybe.fromMaybe "Shadcn" (lookup t visualThemeOptions)

-- | One history-table row: a select checkbox, the timestamp linking to that revision's read view, author, subject, and a Restore button.
revisionRow :: String -> Git.Revision -> Html.Html ()
revisionRow path rev =
    Html.el "tr" [] $ do
        Html.el "td" [] (Html.input [Html.attr "type" "checkbox", Html.class_ "verso-pick", Html.attr "name" "rev", Html.attr "value" (Git.revHash rev)])
        Html.el "td" [] (Html.a [Html.href ("/documents/" ++ path ++ "?at=" ++ Git.revHash rev), Html.attr "title" "View the page at this revision"] (Html.text (Git.revTimestamp rev)))
        Html.el "td" [] (Html.text (Git.revAuthor rev))
        Html.el "td" [] (Html.text (Git.revSubject rev ++ " (" ++ Git.revShort rev ++ ")"))
        Html.el "td" [] $
            Html.el "form" [Html.attr "method" "post", Html.attr "action" ("/documents/" ++ path ++ "?rollback")] $ do
                Html.input [Html.attr "type" "hidden", Html.attr "name" "rev", Html.attr "value" (Git.revHash rev)]
                Chrome.chromeSubmitButton Chrome.OutlineControl [Html.class_ "verso-rollback-button"] (Html.text "Restore")

{- | The history page's client script: wires the Basecoat theme menu and the
scheme button group to the editor's @localStorage@ keys (menuitem clicks on
the dropdown, button clicks on the group), limits revision selection to two,
and as soon as two are selected fetches the side-by-side diff fragment of the
pair (older as @from@, newer as @to@) into the diff pane; with fewer than two
selected the pane is hidden and the hint is shown.
-}
historyScript :: String
historyScript =
    "<script>(function(){var r=document.documentElement;"
        ++ "var labels={shadcn:'Shadcn',studio:'Studio'};"
        ++ "var trig=document.getElementById('verso-theme-trigger');"
        ++ "var ct=localStorage.getItem('editor-theme')||r.getAttribute('data-editor-theme');"
        ++ "if(trig&&ct&&labels[ct]){trig.textContent=labels[ct];}"
        ++ "[].forEach.call(document.querySelectorAll('#verso-theme-menu [role=menuitem]'),function(it){"
        ++ "it.addEventListener('click',function(){var v=it.getAttribute('data-value');"
        ++ "if(v&&labels[v]){localStorage.setItem('editor-theme',v);r.setAttribute('data-editor-theme',v);if(trig){trig.textContent=labels[v];}}});});"
        ++ "var sg=document.getElementById('verso-scheme-group');"
        ++ "function applyScheme(s){var d=s==='dark'||(s!=='light'&&window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches);r.classList.toggle('wa-dark',d);r.classList.toggle('wa-light',!d);r.classList.toggle('dark',d);}"
        ++ "function reflectScheme(v){if(!sg){return;}[].forEach.call(sg.querySelectorAll('[data-scheme]'),function(b){b.setAttribute('aria-checked',b.getAttribute('data-scheme')===v?'true':'false');});}"
        ++ "if(sg){var cs=localStorage.getItem('editor-color-scheme')||'match-system';reflectScheme(cs);"
        ++ "[].forEach.call(sg.querySelectorAll('[data-scheme]'),function(b){b.addEventListener('click',function(){"
        ++ "var v=b.getAttribute('data-scheme');localStorage.setItem('editor-color-scheme',v);applyScheme(v);reflectScheme(v);});});}"
        ++ "var boxes=[].slice.call(document.querySelectorAll('.verso-pick'));"
        ++ "var pane=document.getElementById('verso-diff-pane');var hint=document.getElementById('verso-diff-hint');"
        ++ "var p=pane?pane.getAttribute('data-path'):'';"
        ++ "function picked(){return boxes.filter(function(b){return b.checked;});}"
        ++ "function showHint(){if(pane){pane.hidden=true;pane.innerHTML='';}if(hint){hint.hidden=false;}}"
        ++ "function update(){var c=picked();boxes.forEach(function(b){b.disabled=(c.length>=2&&!b.checked);});"
        ++ "if(c.length===2){var to=c[0].value,from=c[1].value;if(hint){hint.hidden=true;}if(pane){pane.hidden=false;pane.textContent='Loading diff...';"
        ++ "fetch('/documents/'+p+'?diff&pane&from='+encodeURIComponent(from)+'&to='+encodeURIComponent(to))"
        ++ ".then(function(x){return x.text();}).then(function(h){if(pane){pane.innerHTML=h;}}).catch(function(){if(pane){pane.textContent='Could not load diff.';}});}}"
        ++ "else{showHint();}}"
        ++ "boxes.forEach(function(b){b.addEventListener('change',update);});"
        ++ "update();})();</script>"

-- | Renders the standalone diff page (a back link plus the diff body), for a direct @?diff@ link.
diffPage :: String -> String -> String -> String -> String -> String -> Html.Html ()
diffPage themeDefault title path fromRev toRev diff =
    versionPageShell themeDefault ("Diff: " ++ title) $ do
        Html.el "h1" [] (Html.text "Diff")
        Html.p [Html.class_ "verso-version-back"] (Html.a [Html.href ("/documents/" ++ path ++ "?history")] (Html.text "Back to history"))
        diffBody fromRev toRev diff

-- | The diff content (a revision-range caption and the side-by-side table), shared by the diff page and the history pane.
diffBody :: String -> String -> String -> Html.Html ()
diffBody fromRev toRev diff = do
    Html.p [Html.class_ "verso-diff-revs"] (Html.text (take 12 fromRev ++ " to " ++ take 12 toRev))
    if null diff
        then Html.p [] (Html.text "No differences.")
        else sideBySideHtml (sideBySide diff)

-- | A side-by-side diff row: a hunk header, a context line shown on both sides, or a change (removed left, added right; either side may be absent).
data SideRow
    = SideHunk String
    | SideContext String
    | SideChange (Maybe String) (Maybe String)

{- | Parses git's unified (line-based) diff into side-by-side rows: context lines
appear on both sides; within a change block removed lines pair positionally with
added lines (surplus removals show left-only, surplus additions right-only). The
pre-hunk headers (@diff@\/@index@\/@---@\/@+++@) are dropped.
-}
sideBySide :: String -> [SideRow]
sideBySide input = go (dropWhile (not . isHunk) (lines input)) [] []
  where
    isHunk l = take 2 l == "@@"
    go [] dels adds = flush dels adds
    go (l : ls) dels adds = case l of
        ('@' : '@' : _) -> flush dels adds ++ (SideHunk l : go ls [] [])
        (' ' : rest) -> flush dels adds ++ (SideContext rest : go ls [] [])
        ('-' : rest) -> go ls (rest : dels) adds
        ('+' : rest) -> go ls dels (rest : adds)
        _ -> go ls dels adds
    flush dels adds = pair (reverse dels) (reverse adds)
    pair (d : ds) (a : as) = SideChange (Just d) (Just a) : pair ds as
    pair (d : ds) [] = SideChange (Just d) Nothing : pair ds []
    pair [] (a : as) = SideChange Nothing (Just a) : pair [] as
    pair [] [] = []

-- | Renders side-by-side rows as a two-column table with per-cell add/remove highlighting.
sideBySideHtml :: [SideRow] -> Html.Html ()
sideBySideHtml rows =
    Html.el "table" [Html.class_ "verso-diff verso-diff-side"] $
        Html.el "tbody" [] (mapM_ row rows)
  where
    row (SideHunk h) = Html.el "tr" [Html.class_ "verso-diff-hunk"] (Html.el "td" [Html.attr "colspan" "2"] (Html.text h))
    row (SideContext s) = Html.el "tr" [] (cell "verso-diff-ctx" (Just s) >> cell "verso-diff-ctx" (Just s))
    row (SideChange ml mr) = Html.el "tr" [] (cell "verso-diff-del" ml >> cell "verso-diff-add" mr)
    cell _ Nothing = Html.el "td" [Html.class_ "verso-diff-empty"] (Html.text "")
    cell cls (Just s) = Html.el "td" [Html.class_ cls] (Html.text s)
