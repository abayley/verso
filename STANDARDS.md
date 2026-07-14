# Project Coding Standards

- unit tests do no I/O, integration tests do I/O
- fully qualified imports with module aliases
- all functions have haddock docs
- markdown validated with markdownlint
- tests do not produce filesystem artefacts in arbitrary locations, like the
  project root; they write to a temp dir
- always prefer Either over exceptions
- no lazy IO, ever: the semantics are unobvious and differ between compilers
  (GHC's lazy `readFile` locks the file until the string is forced; mhs's does
  not). All IO is strict: text reads via `MicroHttp.FileSystem.readFileStrict`,
  binary reads via strict `Data.ByteString.Char8.readFile`. Large files that
  must not be resident all at once use streaming IO, not laziness
