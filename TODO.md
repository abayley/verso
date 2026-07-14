# Todos

carried over from 2026-07-13 session (RFC-0036 / ADR-080):

- lance FTS optimize panic (SIGABRT, `InnerBuilder::merge_from` OOB in lance-index 7.0.0);
  REPRODUCED 2026-07-14 at ~1/3 storm runs (`scripts/hang-repro.sh`); see
  docs/design/lance-fts-optimize-panic.md (incl. draft upstream issue text);
  likely fixed by upgrading vendored lance (lance#7325 area) with the
  lancedb-c PR work
- search chunking/tokenisation allocation (Concordance, String-heavy);
  the memchr-scan technique from `Verso.DocumentLinks.pageLinks` may apply
  (see docs/design/link-index-performance.md, 2026-07-14 section)
- lancedb-c PR (RFC-0034 era) still to be raised upstream

backend:

- make 404 page offer to create document at this location/URL
- add tags and tag navigation
- auth system
  <https://sinceyouarrived.world/taken>
  <https://givemeyourdata.org/>
  <https://mysysinfo.com/>

- automatic tag classification - create set of canonical tags
- generate image descriptions - gemma4?
- load testing - simulate actual users fetching and saving pages
- would like to notify user when page they are viewing or editing has been modified by someone else; how?
  needs to handle when other users update too - what is the notification mechanism? websockets?
- high-level design doc, with example usage
- hot reload
- raise fault report against haskell time lib
- replace mtl with heftia? what effect libraries will work with microhs?
- database libs: postgres, sqlite, odbc?
- what would it take to support long-polling and websocket applications? e.g. <https://asgi.readthedocs.io/en/latest/specs/www.html>
- middleware functions: auth, security, error reporting, rate lmiting, cors handling, session management
- Html.hs:
  - type alias for attr result: type Attr = (String, String)

frontend:

- implement new themes (currently two: shadcn, studio — View.hs:42)
- test pasting in tables from word or excel
- review code structure
- can we bundle as desktop app?
- all typescript code has tsdocs
- <https://performance.dev/how-is-linear-so-fast-a-technical-breakdown>

done:

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
