# Todos

backend:

- make 404 page offer to create document at this location/URL
- backend with versioning
- add move, delete to navtree - re-implement part of tracker
- add tags and tag navigation

- would like to notify user when page they are viewing or editing has been modified by someone else; how?
  needs to handle when other users update too - what is the notification mechanism? websockets?
- organise code - separate MicroHttp framework from TestApp, rename TestApp to something meaningfull.
  separate FFI-based code to utility modules?
  split TestApp code into pages and markdown validation
- how do we handle markdown frontmatter?
- auth system
- high-level design doc, with example usage
- hot reload
- fully qualified imports with module aliases
- all haskell code has haddock docs
- raise fault report against haskell time lib
- replace mtl with heftia?
- database libs: postgres, sqlite, odbc?
- what would it take to support long-polling and websocket applications? e.g. <https://asgi.readthedocs.io/en/latest/specs/www.html>
- middleware functions: auth, security, error reporting, rate lmiting, cors handling, session management
- Html.hs:
  - type alias for attr result: type Attr = (String, String)

frontend:

- centre editor bar over edit/view panes
- syntax highlighting for code fences
- support for mermaid diagrams
- themes: Roy Lichtenstein (pop-art, line style, solid colour), patrick caulfield, simple (b+w) line art style
- review code structure
- can we bundle as desktop app?
- all typescript code has tsdocs
- <https://performance.dev/how-is-linear-so-fast-a-technical-breakdown>
