# Todos

carried over from 2026-07-13 session (RFC-0036 / ADR-080):

- lancedb-c PR (RFC-0034 era) still to be raised upstream; the vendored clone
  now also carries the lance 8.0.0 dep bump (branch `lance-upgrade-7325`) that
  fixed the FTS optimize panic -- fold it into the PR, and consider reporting
  the 7.0.0 panic upstream (draft text in docs/design/lance-fts-optimize-panic.md)
- raise fault report against haskell time lib

backend:

- make 404 page offer to create document at this location/URL
- add tags and tag navigation
- auth system
  <https://sinceyouarrived.world/taken>
  <https://givemeyourdata.org/>
  <https://mysysinfo.com/>

- reorganise project docs to match standard in aria-evals
- refactor src/Verso/App.hs
  some functions have very large parameter lists: treeRoutes, treePostDispatch, treeDelete, treeDeleteHandler
- automatic tag classification - create set of canonical tags
- generate image descriptions - gemma4?
- test with ghc
- load testing - simulate actual users fetching and saving pages
- would like to notify user when page they are viewing or editing has been modified by someone else; how?
  needs to handle when other users update too - what is the notification mechanism? websockets?
- high-level design doc, with example usage
- hot reload
- replace mtl with heftia? what effect libraries will work with microhs?
- database libs: postgres, sqlite, odbc?
- what would it take to support long-polling and websocket applications? e.g. <https://asgi.readthedocs.io/en/latest/specs/www.html>
- middleware functions: auth, security, error reporting, rate lmiting, cors handling, session management
- Html.hs:
  - type alias for attr result: type Attr = (String, String)
- option to emit static site? probably not worth it; renderer would need to match editor.

frontend:

- editor toolbar: styling buttons do not highlight or stay down to indicate
  which styles are currently in effect
- editor toolbar: can click on the "create link" button with no text selected.
  The link dialogue opens, but Save appears to do nothing.
- bold and italic styling does not round-trip correctly:
  - `***bold italic ***` renders as literal text in Visual mode, not as bold and
    italic
  - `***bold italic***` renders as expected
  - In Visual mode, click Bold, type `b` and a space, click Italic, type `i` and
    a space, click Code, then type `c`. Switching to Markdown mode renders
    `**b *i ***` followed by a code-formatted `c`. Switching back to Visual mode
    shows literal text, not formatting.
- test with no javascript
- investigate watercolour effects for moebius
    the colours have a watercolour feel IMO.
    i want to imitate they way that surfaces look a bit rough and pitted.
    see moebius-girl-on-bench.pjg. look at her hat; how it fades from white to blue, and it has spots on it.
    and the bench and wall behing her do not look clean.
    that's what i was trying for with the speckle.
    can we get a watercolur effect, so that colours are not uniform and flat?
- test pasting in tables from word or excel
- review code structure
- can we bundle as desktop app?
- all typescript code has tsdocs
- <https://performance.dev/how-is-linear-so-fast-a-technical-breakdown>

done:

- 2026-08-07: Publish stages only the current page instead of scanning and
  committing every change in the document tree
- 2026-08-07: code-language picker menus materialise on first interaction, so
  hidden controls no longer make large Visual documents slow to resize
- 2026-07-14: RHS metadata-panel collapse toggle now rotates like the LHS nav
  toggle (transition + rotate(180deg) on data-collapsed)
- 2026-07-14: search results render as clickable Basecoat cards (stretched
  title link, hover tint); search page is instant like the top-bar search
  (search-page.ts: debounced /search?json, URL sync, no submit button) with a
  chrome icon clear button replacing the tiny native search-cancel affordance
- what would moving to react look like? (docs/react.md)
- delete action now uses the HTTP DELETE verb (RFC-0036; client
  markdown-editor-element.ts:608, server DELETE /tree/*path)
- 2026-07-13: search page back link now referrer-based like the trash page
- 2026-07-13: search box / undo dropdown / trash dropdown show "Couldn't reach
  the server." when the listing fetch fails (was silently empty)
- 2026-07-13: editor error notices (save error, upload notice, error banner)
  restyled as Basecoat alerts with an icon dismiss button (chromeAlertEl)
- 2026-07-13: dedicated undo page (GET /undo, per-row Undo) + "View all moves…"
  at the bottom of the undo dropdown
- 2026-07-13: trash page gained Empty trash, per-row Delete forever
  (`DELETE /trash`, `DELETE /trash/<id>`), and trash_retention_days config
  (default 90; sweep runs on trash listing; notice shown on the page)
- 2026-07-13: bubble toolbar no longer offers horizontal-rule (command bar and
  slash menu still do)
- 2026-07-13: code-fence bodies in raw Markdown mode are syntax-highlighted via
  the shared lowlight grammars (codemirror-fence-highlight.ts)
- 2026-07-14: publish-path link parse rebuilt on libc memchr (85MB -> 15MB,
  35ms -> 8ms per 73KB page; `make bench-link-parse`)
- 2026-07-14: startup creates parent dirs for access/client-error/op logs and
  the link index (was: listen-but-fail-every-request)
- 2026-07-14: `make check` runs the browser smoke; its startup poll no longer
  hangs bun on failure
- 2026-07-14: search tokenisation 2.4x less allocation (trie vocab, ASCII
  fast paths, linear chunker; `make bench-search-chunk`)
- 2026-07-14: vendored lancedb upgraded to 0.31.0 / lance 8.0.0; the FTS
  optimize panic no longer reproduces (10/10 storm runs GREEN, was ~1/3 crash)
- 2026-07-14: search pipeline restructured over ByteString (memchr chunker,
  byte-walking tokeniser, page-wide byte-keyed word cache): whole pipeline
  1.9GB -> 544MB and 790ms -> 238ms per page vs the morning baseline
