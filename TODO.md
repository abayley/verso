# Todos

backend:

- make 404 page offer to create document at this location/URL
- add tags and tag navigation
- auth system
  <https://sinceyouarrived.world/taken>
  <https://givemeyourdata.org/>
  <https://mysysinfo.com/>

- search: first term takes about 3s to respond after server start
- automatic tag classification - create set of canonical tags
- generate image descriptions - gemma4?
- openknowledge file format: <https://github.com/GoogleCloudPlatform/knowledge-catalog/blob/main/okf/SPEC.md>
  what would it take to be compliant?
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

- implement new themes
- code fence highlighting in markdown editor
- test pasting in tables from word or excel
- fix UI for trash - maybe separate page?
- review code structure
- can we bundle as desktop app?
- all typescript code has tsdocs
- <https://performance.dev/how-is-linear-so-fast-a-technical-breakdown>
