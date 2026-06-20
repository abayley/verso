# Todos

backend:

- raise fault report against haskell time lib
- replace mtl with heftia?
- ensure logs are rolled
- organise code - separate MicroHttp framework from TestApp, rename TestApp to something meaningfull.
- generated ToC
- plan where images and attachments should go
- would like to notify user when page they are viewing or editing has been modified by someone else; how?
- how do we handle markdown frontmatter?
- auth system
- high-level design doc, with example usage
- hot reload
- fully qualified imports with module aliases
- all haskell code has haddock docs
- split TestApp code into pages and markdown validation
- database libs: postgres, sqlite, odbc?
- what would it take to support long-polling and websocket applications? e.g. <https://asgi.readthedocs.io/en/latest/specs/www.html>
- middleware functions: auth, security, error reporting, rate lmiting, cors handling, session management
- Html.hs:
  - type alias for attr result: type Attr = (String, String)

frontend:

- add navtree on LHS that supports drag + drop and renaming
  needs to handle when other users update too - what is the notification mechanism? websockets?
- themes: Roy Lichtenstein (pop-art, line style, solid colour), patrick caulfield, simple (b+w) line art style
- revisit existing themes: studio, workbench, herbarium lack variation from paper.
  workbench does not look much like the mockup.
- markdown editor colour scheme in dark mode is terrible
- review code structure
- can we bundle as desktop app?
- all typescript code has tsdocs
- <https://performance.dev/how-is-linear-so-fast-a-technical-breakdown>
