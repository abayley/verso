# Todos

carried over from 2026-07-13 session (RFC-0036 / ADR-0080):

- lancedb-c PR (RFC-0034 era) still to be raised upstream; the vendored clone
  now also carries the lance 8.0.0 dep bump (branch `lance-upgrade-7325`) that
  fixed the FTS optimize panic -- fold it into the PR, and consider reporting
  the 7.0.0 panic upstream (draft text in docs/rfcs/refs/lance-fts-optimize-panic.md)
- raise fault report against haskell time lib

backend:

- make 404 page offer to create document at this location/URL
- add tags and tag navigation
- auth system
  <https://sinceyouarrived.world/taken>
  <https://givemeyourdata.org/>
  <https://mysysinfo.com/>

- test with ghc
- profile memory use
- refactor src/Verso/App.hs
  some functions have very large parameter lists: treeRoutes, treePostDispatch, treeDelete, treeDeleteHandler
- automatic tag classification - create set of canonical tags
- generate image descriptions - gemma4?
- add CLI for agents to edit pages
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

- editing collapsible heading makes with toggle between expanded and collapsed states
- adding a code fence inside a collapsible is awkward - it tends to want to capture everything already in there
- if i have a callout then a code block, or multiple code blocks, there's no way to insert empty lines between them.
- default and studio themes have no top-level drop-zone for page moves, once we scroll down
- review editor design/architecture - use archify
  compare with fumadocs editor design
- how much bigger would react make it?
- test with no javascript
- test pasting in tables from word or excel
- review code structure
- can we bundle as desktop app?
- all typescript code has tsdocs
- <https://performance.dev/how-is-linear-so-fast-a-technical-breakdown>

done:

- 2026-08-09: the page tree's top-level drop target pins below the rail header instead
  of scrolling away, so a page can be dropped at the top level from anywhere in a long
  tree without breaking off the drag to scroll up. Invisible until a drag arms it, so
  only Moebius (which paints its sun and moon there) shows a change
- 2026-08-09: Moebius surfaces are no longer flat colour with dots on them.
  The speckle is gone, replaced (not joined) by four wash devices tuned
  against the reference art (ADR-0085): uneven
  low-frequency mottling, a cool-to-warm hue fade whose changeover is dithered
  into stipple, 4px hatching for shadow and contour (the bars' lower edges and
  the scenery hills, never a working surface), and outlined paint-chip flecks
  on the two surfaces that read as objects. Chromatic granulation and edge
  pooling were tried and dropped. The tuning record, and the place to start
  from for any change to the numbers, is
  docs/mockups/markdown-editor-moebius-watercolour-prototype.html
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
