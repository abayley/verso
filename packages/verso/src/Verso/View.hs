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
    DiffScan,
    diffScanInit,
    diffScanStep,
    diffScanFlush,
    diffPageHalves,
    diffPaneHalves,
    editorPage,
    editorShell,
    excerptOf,
    historyPage,
    searchPage,
    trashPage,
    undoPage,
    versionPageShell,
) where

import qualified Concordance.Store as Store
import qualified Control.Monad as Monad
import qualified Data.ByteString.Char8 as BS
import qualified Data.Maybe as Maybe
import qualified MicroHttp.Html as Html
import qualified MicroHttp.Utf8 as Utf8
import qualified Verso.Chrome as Chrome
import qualified Verso.Git as Git
import qualified Verso.Json as Json

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
    Html.meta_ [Html.attr "name" "viewport", Html.attr "content" "width=device-width, initial-scale=1"]
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
    Html.html_ [Html.lang "en"] $ do
        Html.head_ [] $ do
            Html.meta_ [Html.attr "charset" "utf-8"]
            Html.rawTrusted "<script src=\"/static/editor/appearance-bootstrap.js\"></script>"
            Html.title_ [] (Html.text pageTitle)
            chromeHeadAssets
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\" defer></script>"
        Html.body_ [Html.class_ "markdown-editor-page verso-version-page"] $
            Html.main_ [] bodyContent

{- | The search page: the query form and, when search ran, its results.
The outcome 'Nothing' means search is not enabled on this server; the origin
is the page the search was opened from (its Referer), for the back link.
-}
searchPage :: Maybe String -> String -> Maybe ([Store.Hit], Int) -> Html.Html ()
searchPage origin query outcome =
    versionPageShell "Search" $ do
        versionControls
        Html.h1_ [] (Html.text "Search")
        Html.p_ [Html.class_ "verso-version-back"] (backLink origin)
        -- The form still submits as a plain GET without JS; search-page.ts intercepts
        -- it for instant results, so there is no submit button. The clear button is a
        -- comfortable chrome icon button in place of the tiny native search-cancel
        -- affordance (the same trade the top-bar SearchPanel makes).
        Html.form_ [Html.attr "method" "get", Html.attr "action" "/search", Html.class_ "verso-search-form"] $
            Html.div_ [Html.class_ "verso-search-box"] $ do
                Html.input_ [Html.class_ "input", Html.attr "type" "search", Html.attr "name" "q", Html.attr "value" query, Html.attr "placeholder" "Search the wiki", Html.attr "autofocus" ""]
                Chrome.chromeButton
                    Chrome.IconControl
                    (("class", "verso-search-clear") : ("aria-label", "Clear search") : [("hidden", "") | null query])
                    (Chrome.chromeIcon "x")
        case outcome of
            Nothing ->
                Html.p_ [] (Html.text "Search is not enabled on this server (see search_enabled and make search-shim).")
            Just (hits, depth) ->
                -- The region search-page.ts re-renders on each keystroke; its absence
                -- (search disabled) leaves the enhancement inert.
                Html.div_ [Html.class_ "verso-search-output"] $ do
                    Monad.when (depth > 0) $
                        Html.p_ [Html.class_ "verso-search-pending"] (Html.text ("Indexing in progress: " ++ show depth ++ " page(s) pending; results may be incomplete."))
                    Monad.unless (null query) $
                        if null hits
                            then Html.p_ [] (Html.text "No results.")
                            else Html.ol_ [Html.class_ "verso-search-results"] (mapM_ searchResult hits)

{- | One search result as a Basecoat card: the header links the page (and
section), the body is a text excerpt.
-}
searchResult :: Store.Hit -> Html.Html ()
searchResult hit =
    Html.li_ [Html.class_ "card verso-search-result"] $ do
        Html.header_ [] $
            Html.h2_ [Html.class_ "verso-search-hit"] $ do
                Html.a_ [Html.href ("/documents/" ++ Store.hitPage hit)] (Html.text (Store.hitPage hit))
                Monad.unless (null (Store.hitAnchor hit)) $
                    Html.span_ [Html.class_ "verso-search-anchor"] (Html.text (" > " ++ Store.hitAnchor hit))
        Html.section_ [] $
            Html.p_ [Html.class_ "verso-search-excerpt"] (Html.text (excerptOf (Store.hitText hit)))

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
        Html.h1_ [] (Html.text "Trash")
        Html.p_ [Html.class_ "verso-version-back"] (backLink origin)
        Monad.when (retentionDays > 0) $
            Html.p_
                [Html.class_ "verso-trash-retention"]
                (Html.text ("Items older than " ++ show retentionDays ++ " days will be permanently deleted."))
        if null entries
            then Html.p_ [] (Html.text "Trash is empty.")
            else do
                Html.p_ [] $
                    Chrome.chromeButton
                        Chrome.DangerAction
                        [Html.class_ "verso-trash-empty"]
                        (Html.text "Empty trash")
                Html.div_ [Html.class_ "verso-trash-scroll"] $
                    Html.el "table" [Html.class_ "verso-trash"] $ do
                        Html.el "thead" [] (Html.el "tr" [] (mapM_ (Html.el "th" [] . Html.text) ["When", "Item", "Kind", ""]))
                        Html.el "tbody" [] (mapM_ trashRow entries)

-- | The trash and search pages' back link: to the originating page when known, else the wiki root.
backLink :: Maybe String -> Html.Html ()
backLink Nothing = Html.a_ [Html.href "/documents/"] (Html.text "Back to the wiki")
backLink (Just path) = Html.a_ [Html.href ("/documents/" ++ path)] (Html.text ("Back to " ++ path))

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
        Html.h1_ [] (Html.text "Undo")
        Html.p_ [Html.class_ "verso-version-back"] (backLink origin)
        if null entries
            then Html.p_ [] (Html.text "No moves to undo.")
            else Html.div_ [Html.class_ "verso-trash-scroll"] $
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
        Html.h1_ [] (Html.text "Revision history")
        Html.p_ [Html.class_ "verso-version-back"] (Html.a_ [Html.href ("/documents/" ++ path)] (Html.text ("Back to " ++ path)))
        if null revs
            then Html.p_ [] (Html.text "No revisions yet.")
            else do
                Html.div_ [Html.class_ "verso-history-scroll"] $
                    Html.el "table" [Html.class_ "verso-history"] $ do
                        Html.el "thead" [] (Html.el "tr" [] (mapM_ (Html.el "th" [] . Html.text) ["", "When", "Who", "Message", ""]))
                        Html.el "tbody" [] (mapM_ (revisionRow path) revs)
                Html.p_ [Html.attr "id" "verso-diff-hint", Html.class_ "verso-diff-hint"] (Html.text "Select two revisions to see a side-by-side diff.")
                Html.div_ [Html.attr "id" "verso-diff-pane", Html.class_ "verso-diff-pane", Html.attr "data-path" path, Html.attr "hidden" ""] (pure ())
                Html.rawTrusted historyScript

{- | The generic host where the deferred browser bundle renders standalone
appearance controls. With JavaScript disabled, the host stays empty.
-}
versionControls :: Html.Html ()
versionControls =
    Html.div_ [Html.class_ "markdown-editor__toolbar markdown-editor__toolbar--top verso-version-toolbar"] $
        Html.div_ [Html.class_ "markdown-editor__toolbar-controls"] $
            Html.div_
                [ Html.class_ "markdown-editor__appearance"
                , Html.attr "id" "verso-appearance-controls"
                ]
                (pure ())

-- | One history-table row: a select checkbox, the timestamp linking to that revision's read view, author, subject, and a Restore button.
revisionRow :: String -> Git.Revision -> Html.Html ()
revisionRow path rev =
    Html.el "tr" [] $ do
        Html.el "td" [] (Html.input_ [Html.attr "type" "checkbox", Html.class_ "verso-pick", Html.attr "name" "rev", Html.attr "value" (Git.revHash rev)])
        Html.el "td" [] (Html.a_ [Html.href ("/documents/" ++ path ++ "?at=" ++ Git.revHash rev), Html.attr "title" "View the page at this revision"] (Html.text (Git.revTimestamp rev)))
        Html.el "td" [] (Html.text (Git.revAuthor rev))
        Html.el "td" [] (Html.text (Git.revSubject rev ++ " (" ++ Git.revShort rev ++ ")"))
        Html.el "td" [] $
            Html.form_ [Html.attr "method" "post", Html.attr "action" ("/documents/" ++ path ++ "?rollback")] $ do
                Html.input_ [Html.attr "type" "hidden", Html.attr "name" "rev", Html.attr "value" (Git.revHash rev)]
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
    versionPageShell ("Diff: " ++ title) (diffChrome path >> diffBody fromRev toRev diff)

-- | The page-only chrome above the diff content: the heading and the back link.
diffChrome :: String -> Html.Html ()
diffChrome path = do
    Html.h1_ [] (Html.text "Diff")
    Html.p_ [Html.class_ "verso-version-back"] (Html.a_ [Html.href ("/documents/" ++ path ++ "?history")] (Html.text "Back to history"))

-- | The diff content (a revision-range caption and the side-by-side table), shared by the diff page and the history pane.
diffBody :: String -> String -> String -> Html.Html ()
diffBody fromRev toRev diff = do
    diffRevs fromRev toRev
    if null diff
        then Html.p_ [] (Html.text "No differences.")
        else diffTable (sideBySide diff)

-- | The revision-range caption above a diff.
diffRevs :: String -> String -> Html.Html ()
diffRevs fromRev toRev = Html.p_ [Html.class_ "verso-diff-revs"] (Html.text (take 12 fromRev ++ " to " ++ take 12 toRev))

-- | The side-by-side table wrapper around its rows.
diffTable :: [SideRow] -> Html.Html ()
diffTable rows = Html.el "table" [Html.class_ "verso-diff verso-diff-side"] (Html.el "tbody" [] (mapM_ renderSideRow rows))

-- | A side-by-side diff row: a hunk header, a context line shown on both sides, or a change (removed left, added right; either side may be absent).
data SideRow
    = SideHunk String
    | SideContext String
    | SideChange (Maybe String) (Maybe String)

-- | Renders one side-by-side row as a table row with per-cell add/remove highlighting.
renderSideRow :: SideRow -> Html.Html ()
renderSideRow (SideHunk h) = Html.el "tr" [Html.class_ "verso-diff-hunk"] (Html.el "td" [Html.attr "colspan" "2"] (Html.text h))
renderSideRow (SideContext s) = Html.el "tr" [] (cell "verso-diff-ctx" (Just s) >> cell "verso-diff-ctx" (Just s))
renderSideRow (SideChange ml mr) = Html.el "tr" [] (cell "verso-diff-del" ml >> cell "verso-diff-add" mr)

-- | One diff table cell: a class and its text, or an empty cell.
cell :: String -> Maybe String -> Html.Html ()
cell _ Nothing = Html.el "td" [Html.class_ "verso-diff-empty"] (Html.text "")
cell cls (Just s) = Html.el "td" [Html.class_ cls] (Html.text s)

{- | Parses git's unified (line-based) diff into side-by-side rows: context lines
appear on both sides; within a change block removed lines pair positionally with
added lines (surplus removals show left-only, surplus additions right-only). The
pre-hunk headers (@diff@\/@index@\/@---@\/@+++@) are dropped. Kept for the
whole-string callers; the streamed diff response uses 'diffScanStep' over the same
rules (RFC-0040).
-}
sideBySide :: String -> [SideRow]
sideBySide input = go (dropWhile (not . isHunk) (lines input)) [] []
  where
    go [] dels adds = flushChange dels adds
    go (l : ls) dels adds = case l of
        ('@' : '@' : _) -> flushChange dels adds ++ (SideHunk l : go ls [] [])
        (' ' : rest) -> flushChange dels adds ++ (SideContext rest : go ls [] [])
        ('-' : rest) -> go ls (rest : dels) adds
        ('+' : rest) -> go ls dels (rest : adds)
        _ -> go ls dels adds

-- | Whether a diff line is a hunk header.
isHunk :: String -> Bool
isHunk l = take 2 l == "@@"

-- | Pairs buffered removed and added lines (given oldest-first) into change rows.
flushChange :: [String] -> [String] -> [SideRow]
flushChange dels adds = pair (reverse dels) (reverse adds)
  where
    pair (d : ds) (a : as) = SideChange (Just d) (Just a) : pair ds as
    pair (d : ds) [] = SideChange (Just d) Nothing : pair ds []
    pair [] (a : as) = SideChange Nothing (Just a) : pair [] as
    pair [] [] = []

{- | The streamed diff parser's state: whether the first hunk has been seen (lines
before it are dropped), and the removed/added lines buffered within the current
change block (newest-first). Bounded by one change block, never the whole diff.
-}
data DiffScan = DiffScan Bool [String] [String]

-- | The initial scan state, before any line.
diffScanInit :: DiffScan
diffScanInit = DiffScan False [] []

{- | Folds one diff line into the scan, returning the new state and the HTML bytes
of any rows it completed. Byte-identical, row for row, to 'sideBySide' followed by
'renderSideRow': the same rules, applied a line at a time so no whole-diff value is
built (RFC-0040).
-}
diffScanStep :: DiffScan -> BS.ByteString -> (DiffScan, BS.ByteString)
diffScanStep (DiffScan haveHunk dels adds) lineBytes =
    let line = Utf8.decodeBytes lineBytes -- decoded once here; Html.text encodes it again on the way out
     in if not haveHunk
            then
                if isHunk line
                    then (DiffScan True [] [], renderRows [SideHunk line])
                    else (DiffScan False dels adds, BS.empty)
            else case line of
                ('@' : '@' : _) -> (DiffScan True [] [], renderRows (flushChange dels adds ++ [SideHunk line]))
                (' ' : rest) -> (DiffScan True [] [], renderRows (flushChange dels adds ++ [SideContext rest]))
                ('-' : rest) -> (DiffScan True (rest : dels) adds, BS.empty)
                ('+' : rest) -> (DiffScan True dels (rest : adds), BS.empty)
                _ -> (DiffScan True dels adds, BS.empty)

-- | The HTML bytes of the rows still buffered at end of input.
diffScanFlush :: DiffScan -> BS.ByteString
diffScanFlush (DiffScan _ dels adds) = renderRows (flushChange dels adds)

-- | The HTML bytes of a list of rows, concatenated.
renderRows :: [SideRow] -> BS.ByteString
renderRows = BS.concat . map (BS.concat . Html.renderChunksRaw . renderSideRow)

{- | The chrome bytes before and after the streamed rows for the full diff page,
obtained by rendering the real page with a single sentinel row and splitting there,
so the halves are byte-identical to 'diffPage' with its rows in place (RFC-0040).
The caller prepends the doctype, as 'documentResponse' does.
-}
diffPageHalves :: String -> String -> String -> String -> (BS.ByteString, BS.ByteString)
diffPageHalves title path fromRev toRev =
    splitAroundSentinel (versionPageShell ("Diff: " ++ title) (diffChrome path >> diffRevs fromRev toRev >> diffTable [sentinelRow]))

-- | As 'diffPageHalves', for the bare history-pane fragment (no page shell).
diffPaneHalves :: String -> String -> (BS.ByteString, BS.ByteString)
diffPaneHalves fromRev toRev =
    splitAroundSentinel (diffRevs fromRev toRev >> diffTable [sentinelRow])

-- | A unique row whose rendered bytes mark where the streamed rows are spliced in.
sentinelRow :: SideRow
sentinelRow = SideHunk "\SOH\SOHverso-diff-rows-hole\SOH\SOH"

-- | Splits rendered HTML around the sentinel row's bytes into (before, after).
splitAroundSentinel :: Html.Html () -> (BS.ByteString, BS.ByteString)
splitAroundSentinel html =
    let whole = BS.concat (Html.renderChunks html)
        needle = BS.concat (Html.renderChunksRaw (renderSideRow sentinelRow))
        (before, rest) = BS.breakSubstring needle whole
     in (before, BS.drop (BS.length needle) rest)

{- | The page's attachments as a compact JSON array of @{"name","localPath"}@
objects, embedded on the editor element for the metadata panel (RFC-0019). Strings
are JSON-escaped; the surrounding HTML attribute is escaped by the renderer.
-}
attachmentsJson :: [(String, String)] -> String
attachmentsJson entries = Json.render (Json.array (map attachmentObject entries))
  where
    attachmentObject (name, localPath) =
        Json.object [("name", Json.string name), ("localPath", Json.string localPath)]

-- | A breadcrumb in the path navigation: a visible label and an optional link (Nothing for the current page).
data Crumb = Crumb String (Maybe String)

-- | The breadcrumb trail as a JSON array of @{"label","href"}@ (href omitted for the current page).
breadcrumbsJson :: [Crumb] -> String
breadcrumbsJson crumbs = Json.render (Json.array (map crumbObject crumbs))
  where
    crumbObject (Crumb label href) =
        Json.object (("label", Json.string label) : maybe [] (\h -> [("href", Json.string h)]) href)

editorPage :: String -> Maybe String -> String -> Html.Escaped -> Bool -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> Html.Html ()
editorPage docId mode pageTitle content versioned editable hasDraft attachments breadcrumbs treeSpine =
    before >> Html.escapedText content >> after
  where
    (before, after) = editorShell docId mode pageTitle versioned editable hasDraft attachments breadcrumbs treeSpine

{- | The editor page split at the document hole (RFC-0040): the shell before the
@\<textarea\>@'s content and the shell after it, as two 'Html' values. A caller
that has the content rebuilds the whole page with 'editorPage'; a caller streaming
the document from disk emits @before@, the escaped document, then @after@, with a
@Content-Length@ summed from the shells' lengths and the escaped document's length.

The read view (RFC-0020) has no write path: the element is rendered without the
surrounding autosave form and marked read-only so the editors and chrome disable
editing. @data-readonly@, @data-versioning@ (RFC-0036) and @data-has-draft@
(RFC-0032) are the same server-set attributes the whole page carried. The split
is byte-identical to the un-split page: 'Html.elOpen' and 'Html.elClose' emit the
tags the content nested between.
-}
editorShell :: String -> Maybe String -> String -> Bool -> Bool -> Bool -> [(String, String)] -> [Crumb] -> String -> (Html.Html (), Html.Html ())
editorShell docId mode pageTitle versioned editable hasDraft attachments breadcrumbs treeSpine =
    (before, after)
  where
    editorAttrs =
        [Html.attr "name" "markdown", Html.attr "data-document" docId]
            ++ maybe [] (\m -> [Html.attr "mode" m]) mode
            ++ [Html.attr "data-attachments" (attachmentsJson attachments) | not (null attachments)]
            ++ [Html.attr "data-breadcrumbs" (breadcrumbsJson breadcrumbs) | not (null breadcrumbs)]
            ++ [Html.attr "data-tree-spine" treeSpine | not (null treeSpine)]
            ++ [Html.attr "data-readonly" "" | not editable]
            ++ [Html.attr "data-versioning" "" | versioned]
            ++ [Html.attr "data-has-draft" "" | hasDraft]
    textareaAttrs =
        [Html.attr "name" "markdown", Html.attr "aria-label" "Markdown source", Html.class_ "markdown-editor__fallback"]
    before = do
        Html.elOpen "html" [Html.lang "en"]
        Html.head_ [] $ do
            Html.meta_ [Html.attr "charset" "utf-8"]
            Html.rawTrusted "<script src=\"/static/editor/appearance-bootstrap.js\"></script>"
            Html.title_ [] (Html.text pageTitle)
            chromeHeadAssets
            Html.rawTrusted "<script src=\"/static/editor/markdown-editor.js\" defer></script>"
        Html.elOpen "body" [Html.class_ "markdown-editor-page"]
        Html.elOpen "main" []
        -- The no-JavaScript save form (RFC-0042): the server routes each field by name
        -- as it arrives, so any control field added to this form must come before the
        -- textarea, never after it.
        Monad.when editable $
            Html.elOpen "form" [Html.attr "action" ("/documents/" ++ docId), Html.attr "method" "post"]
        Html.elOpen "markdown-editor" editorAttrs
        Html.elOpen "textarea" textareaAttrs
    after = do
        Html.elClose "textarea"
        Html.elClose "markdown-editor"
        Monad.when editable $ do
            Html.custom "noscript" [] $
                Html.button_ [Html.attr "type" "submit"] (Html.text "Save")
            Html.elClose "form"
        Html.elClose "main"
        Html.elClose "body"
        Html.elClose "html"
