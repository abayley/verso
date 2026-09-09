{- | Page rendering extracted from the request handlers (RFC-0035).

App.hs keeps routing and handlers; this module owns page shells and whole-page
views. Appearance behaviour belongs to the browser modules, never in handler
or view code.
-}
module Verso.View (
    Crumb (..),
    chromeHeadAssets,
    diffBody,
    diffPage,
    editorPage,
    excerptOf,
    historyPage,
    jsonArray,
    jsonBool,
    jsonObject,
    jsonString,
    searchPage,
    trashPage,
    undoPage,
    versionPageShell,
) where

import qualified Concordance.Store as Store
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.List as List
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Html as Html
import qualified Verso.Chrome as Chrome
import qualified Verso.Git as Git

{- | The head tags shared by every full page: the responsive viewport, the
vendored Roboto and Roboto Mono fonts, the Basecoat chrome bundle (RFC-0035),
and the app stylesheet. Order matters: Basecoat loads before the app stylesheet
so un-layered app rules win the cascade. Both scripts are deferred, so the
editor bundle now runs after Basecoat's runtime rather than before it, and
initBasecoat finds the runtime already present.

The viewport tag is what makes the narrow layouts reachable at all: without it
a phone browser lays the page out at a ~980px virtual viewport and scales the
result down, so the narrow breakpoints never match on a real device (only when
a desktop window is resized). It lives here so no page shell can omit it.
-}
chromeHeadAssets :: Html.Html ()
chromeHeadAssets = do
    Html.meta [Html.attr "name" "viewport", Html.attr "content" "width=device-width, initial-scale=1"]
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/roboto.css\">"
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/roboto-mono.css\">"
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/basecoat.css\">"
    Html.rawTrusted "<link rel=\"stylesheet\" href=\"/static/editor/markdown-editor.css\">"
    Html.rawTrusted "<script src=\"/static/editor/basecoat.js\" defer></script>"
    Html.rawTrusted chromeInitScript

{- | Scans for uninitialised Basecoat components on load (Lit elements call
initAll from their own updated() hooks; initAll is idempotent).
-}
chromeInitScript :: String
chromeInitScript =
    "<script>(function(){function i(){window.basecoat&&window.basecoat.initAll();}"
        ++ "document.addEventListener('DOMContentLoaded',i);})()</script>"

{- | The full-page shell shared by the history, diff, and search views. It
loads the browser appearance bootstrap before the shared stylesheets and loads
the deferred editor bundle so its chrome behaviours are available. The
@\<markdown-editor\>@ element the bundle also defines is simply unused on
these pages.
-}
versionPageShell :: String -> Html.Html () -> Html.Html ()
versionPageShell pageTitle bodyContent =
    Html.html [Html.lang "en"] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.rawTrusted "<script src=\"/static/editor/appearance-bootstrap.js\"></script>"
            Html.title [] (Html.text pageTitle)
            chromeHeadAssets
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\" defer></script>"
        Html.body [Html.class_ "markdown-editor-page verso-version-page"] $
            Html.main [] bodyContent

{- | The search page: the query form and, when search ran, its results.
The outcome 'Nothing' means search is not enabled on this server; the origin
is the page the search was opened from (its Referer), for the back link.
-}
searchPage :: Maybe String -> String -> Maybe ([Store.Hit], Int) -> Html.Html ()
searchPage origin query outcome =
    versionPageShell "Search" $ do
        versionControls
        Html.el "h1" [] (Html.text "Search")
        Html.p [Html.class_ "verso-version-back"] (backLink origin)
        -- The form still submits as a plain GET without JS; search-page.ts intercepts
        -- it for instant results, so there is no submit button. The clear button is a
        -- comfortable chrome icon button in place of the tiny native search-cancel
        -- affordance (the same trade the top-bar SearchPanel makes).
        Html.el "form" [Html.attr "method" "get", Html.attr "action" "/search", Html.class_ "verso-search-form"] $
            Html.el "div" [Html.class_ "verso-search-box"] $ do
                Html.input [Html.class_ "input", Html.attr "type" "search", Html.attr "name" "q", Html.attr "value" query, Html.attr "placeholder" "Search the wiki", Html.attr "autofocus" ""]
                Chrome.chromeButton
                    Chrome.IconControl
                    (("class", "verso-search-clear") : ("aria-label", "Clear search") : [("hidden", "") | null query])
                    (Chrome.chromeIcon "x")
        case outcome of
            Nothing ->
                Html.p [] (Html.text "Search is not enabled on this server (see search_enabled and make search-shim).")
            Just (hits, depth) ->
                -- The region search-page.ts re-renders on each keystroke; its absence
                -- (search disabled) leaves the enhancement inert.
                Html.el "div" [Html.class_ "verso-search-output"] $ do
                    Monad.when (depth > 0) $
                        Html.p [Html.class_ "verso-search-pending"] (Html.text ("Indexing in progress: " ++ show depth ++ " page(s) pending; results may be incomplete."))
                    Monad.unless (null query) $
                        if null hits
                            then Html.p [] (Html.text "No results.")
                            else Html.el "ol" [Html.class_ "verso-search-results"] (mapM_ searchResult hits)

{- | One search result as a Basecoat card: the header links the page (and
section), the body is a text excerpt.
-}
searchResult :: Store.Hit -> Html.Html ()
searchResult hit =
    Html.el "li" [Html.class_ "card verso-search-result"] $ do
        Html.el "header" [] $
            Html.el "h2" [Html.class_ "verso-search-hit"] $ do
                Html.a [Html.href ("/documents/" ++ Store.hitPage hit)] (Html.text (Store.hitPage hit))
                Monad.unless (null (Store.hitAnchor hit)) $
                    Html.el "span" [Html.class_ "verso-search-anchor"] (Html.text (" > " ++ Store.hitAnchor hit))
        Html.el "section" [] $
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

{- | The trash page (RFC-0028): every restorable item, newest-first, with a
per-row Restore and Delete forever, plus an Empty-trash control and the
retention notice. The buttons carry the entry id and path as data attributes;
@trash-page.ts@ (loaded with the shared bundle) confirms, sends the request,
and updates the page. Entries are @(id, originalPath, kind, deletedAt)@.
-}
trashPage :: Maybe String -> Int -> [(String, String, String, String)] -> Html.Html ()
trashPage origin retentionDays entries =
    versionPageShell "Trash" $ do
        versionControls
        Html.el "h1" [] (Html.text "Trash")
        Html.p [Html.class_ "verso-version-back"] (backLink origin)
        Monad.when (retentionDays > 0) $
            Html.p
                [Html.class_ "verso-trash-retention"]
                (Html.text ("Items older than " ++ show retentionDays ++ " days will be permanently deleted."))
        if null entries
            then Html.p [] (Html.text "Trash is empty.")
            else do
                Html.p [] $
                    Chrome.chromeButton
                        Chrome.DangerAction
                        [Html.class_ "verso-trash-empty"]
                        (Html.text "Empty trash")
                Html.div [Html.class_ "verso-trash-scroll"] $
                    Html.el "table" [Html.class_ "verso-trash"] $ do
                        Html.el "thead" [] (Html.el "tr" [] (mapM_ (Html.el "th" [] . Html.text) ["When", "Item", "Kind", ""]))
                        Html.el "tbody" [] (mapM_ trashRow entries)

-- | The trash and search pages' back link: to the originating page when known, else the wiki root.
backLink :: Maybe String -> Html.Html ()
backLink Nothing = Html.a [Html.href "/documents/"] (Html.text "Back to the wiki")
backLink (Just path) = Html.a [Html.href ("/documents/" ++ path)] (Html.text ("Back to " ++ path))

-- | One trash-table row: deletion time, the original path, kind, and the Restore / Delete forever controls.
trashRow :: (String, String, String, String) -> Html.Html ()
trashRow (entryId, path, kind, ts) =
    Html.el "tr" [Html.class_ "verso-trash-row"] $ do
        Html.el "td" [] (Html.text ts)
        Html.el "td" [] (Html.text path)
        Html.el "td" [] (Html.text kind)
        Html.el "td" [] $ do
            Chrome.chromeButton
                Chrome.OutlineControl
                [ Html.class_ "verso-trash-restore"
                , Html.attr "data-restore-id" entryId
                , Html.attr "data-restore-path" path
                ]
                (Html.text "Restore")
            Chrome.chromeButton
                Chrome.DangerAction
                [ Html.class_ "verso-trash-delete"
                , Html.attr "data-delete-id" entryId
                , Html.attr "data-delete-path" path
                ]
                (Html.text "Delete forever")

{- | The undo page: every logged move, newest-first, with a per-row Undo, for
when the recent-moves dropdown is too small. The Undo button carries the
operation seq and both paths as data attributes; @undo-page.ts@ (loaded with
the shared bundle) confirms, posts to @\/undo@, and reloads. Entries are
@(seq, from, to, ts)@.
-}
undoPage :: Maybe String -> [(String, String, String, String)] -> Html.Html ()
undoPage origin entries =
    versionPageShell "Undo" $ do
        versionControls
        Html.el "h1" [] (Html.text "Undo")
        Html.p [Html.class_ "verso-version-back"] (backLink origin)
        if null entries
            then Html.p [] (Html.text "No moves to undo.")
            else Html.div [Html.class_ "verso-trash-scroll"] $
                Html.el "table" [Html.class_ "verso-trash verso-undo"] $ do
                    Html.el "thead" [] (Html.el "tr" [] (mapM_ (Html.el "th" [] . Html.text) ["When", "From", "To", ""]))
                    Html.el "tbody" [] (mapM_ undoRow entries)

-- | One undo-table row: the move's time, source, destination, and an Undo control.
undoRow :: (String, String, String, String) -> Html.Html ()
undoRow (seqNo, from, to, ts) =
    Html.el "tr" [Html.class_ "verso-undo-row"] $ do
        Html.el "td" [] (Html.text ts)
        Html.el "td" [] (Html.text from)
        Html.el "td" [] (Html.text to)
        Html.el "td" [] $
            Chrome.chromeButton
                Chrome.OutlineControl
                [ Html.class_ "verso-undo-apply"
                , Html.attr "data-undo-seq" seqNo
                , Html.attr "data-undo-from" from
                , Html.attr "data-undo-to" to
                ]
                (Html.text "Undo")

{- | Renders the revision-history page: theme\/appearance controls, a
fixed-height scrollable table of revisions (each timestamp links to that
revision in the read-only view, with a per-row Restore), and a diff pane below
that appears automatically, side-by-side, once two revisions are selected.
-}
historyPage :: String -> String -> [Git.Revision] -> Html.Html ()
historyPage title path revs =
    versionPageShell ("History: " ++ title) $ do
        versionControls
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

{- | The generic host where the deferred browser bundle renders standalone
appearance controls. With JavaScript disabled, the host stays empty.
-}
versionControls :: Html.Html ()
versionControls =
    Html.div [Html.class_ "markdown-editor__toolbar markdown-editor__toolbar--top verso-version-toolbar"] $
        Html.div [Html.class_ "markdown-editor__toolbar-controls"] $
            Html.div
                [ Html.class_ "markdown-editor__appearance"
                , Html.attr "id" "verso-appearance-controls"
                ]
                (pure ())

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

{- | The history page's client script limits revision selection to two and, as
soon as two are selected, fetches the side-by-side diff fragment of the pair
(older as @from@, newer as @to@) into the diff pane. With fewer than two
selected the pane is hidden and the hint is shown. The shared editor bundle
wires the appearance controls on every version page.
-}
historyScript :: String
historyScript =
    "<script>(function(){var boxes=[].slice.call(document.querySelectorAll('.verso-pick'));"
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
diffPage :: String -> String -> String -> String -> String -> Html.Html ()
diffPage title path fromRev toRev diff =
    versionPageShell ("Diff: " ++ title) $ do
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

{- | The page's attachments as a compact JSON array of @{"name","localPath"}@
objects, embedded on the editor element for the metadata panel (RFC-0019). Strings
are JSON-escaped; the surrounding HTML attribute is escaped by the renderer.
-}
attachmentsJson :: [(String, String)] -> String
attachmentsJson entries = jsonArray (map attachmentObject entries)
  where
    attachmentObject (name, localPath) =
        jsonObject [("name", jsonString name), ("localPath", jsonString localPath)]

{- | A JSON object from @(key, rendered value)@ pairs, in the given order. The
keys are escaped; each value is emitted verbatim, so the caller picks its
rendering -- 'jsonString' for text, 'show' for a number, @"true"@\/@"false"@ for
a boolean, or a nested 'jsonObject' \/ 'jsonArray'. Preferred over writing the
braces and commas by hand, which is where the escaping and separators get lost.
-}
jsonObject :: [(String, String)] -> String
jsonObject fields = "{" ++ List.intercalate "," (map field fields) ++ "}"
  where
    field (key, value) = jsonString key ++ ":" ++ value

{- | A JSON array from already-rendered elements, in the given order (the
element counterpart of 'jsonObject').
-}
jsonArray :: [String] -> String
jsonArray items = "[" ++ List.intercalate "," items ++ "]"

-- | A JSON boolean literal, for use as a 'jsonObject' value.
jsonBool :: Bool -> String
jsonBool True = "true"
jsonBool False = "false"

-- | A JSON string literal: the value wrapped in quotes with the structural characters escaped.
jsonString :: String -> String
jsonString s = "\"" ++ concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c = [c]

-- | A breadcrumb in the path navigation: a visible label and an optional link (Nothing for the current page).
data Crumb = Crumb String (Maybe String)

-- | The breadcrumb trail as a JSON array of @{"label","href"}@ (href omitted for the current page).
breadcrumbsJson :: [Crumb] -> String
breadcrumbsJson crumbs = jsonArray (map crumbObject crumbs)
  where
    crumbObject (Crumb label href) =
        jsonObject (("label", jsonString label) : maybe [] (\h -> [("href", jsonString h)]) href)

editorPage :: String -> Maybe String -> String -> BS.ByteString -> Bool -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> Html.Html ()
editorPage docId mode pageTitle content versioned editable hasDraft attachments breadcrumbs treeSpine =
    Html.html [Html.lang "en"] $ do
        Html.head [] $ do
            Html.meta [Html.attr "charset" "utf-8"]
            Html.rawTrusted "<script src=\"/static/editor/appearance-bootstrap.js\"></script>"
            Html.title [] (Html.text pageTitle)
            chromeHeadAssets
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\" defer></script>"
        Html.body [Html.class_ "markdown-editor-page"] $
            Html.main [] $
                -- The read view (RFC-0020) has no write path: the element is rendered without the
                -- surrounding autosave form, and marked read-only so the editors and chrome disable editing.
                if editable
                    then Html.form_
                        [ Html.attr "action" ("/documents/" ++ docId)
                        , Html.attr "method" "post"
                        ]
                        $ do
                            editorElement docId mode versioned editable hasDraft attachments breadcrumbs treeSpine content
                            Html.custom "noscript" [] $
                                Html.button_ [Html.attr "type" "submit"] (Html.text "Save")
                    else editorElement docId mode versioned editable hasDraft attachments breadcrumbs treeSpine content

{- | The @\<markdown-editor\>@ custom element with its server-set attributes and the
no-script @\<textarea\>@ fallback holding the document. @data-readonly@ is set in the
read view (RFC-0020); the element disables editing and hides the editing chrome.
-}
editorElement :: String -> Maybe String -> Bool -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> BS.ByteString -> Html.Html ()
editorElement docId mode versioned editable hasDraft attachments breadcrumbs treeSpine content =
    Html.custom
        "markdown-editor"
        ( [Html.attr "name" "markdown", Html.attr "data-document" docId]
            ++ maybe [] (\m -> [Html.attr "mode" m]) mode
            ++ [Html.attr "data-attachments" (attachmentsJson attachments) | not (null attachments)]
            ++ [Html.attr "data-breadcrumbs" (breadcrumbsJson breadcrumbs) | not (null breadcrumbs)]
            ++ [Html.attr "data-tree-spine" treeSpine | not (null treeSpine)]
            ++ [Html.attr "data-readonly" "" | not editable]
            -- RFC-0036: versioning on means autosave targets the draft resource (PUT /drafts/<path>).
            ++ [Html.attr "data-versioning" "" | versioned]
            -- RFC-0032: marks a page that has an unpublished draft, so the read view can flag it.
            ++ [Html.attr "data-has-draft" "" | hasDraft]
        )
        ( Html.custom
            "textarea"
            [Html.attr "name" "markdown", Html.attr "aria-label" "Markdown source", Html.class_ "markdown-editor__fallback"]
            (Html.bytesText content)
        )
