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
- no MicroHs-only syntax in code GHC also compiles. `src/`, `test/unit/`, and
  `test/integration/` are built by both `mhs` and by GHC for `make coverage`, so
  they use only syntax both accept. In particular, no `s"a=${x}"` string
  interpolation and no `M."literal"` qualified strings (both are MicroHs
  extensions). Interpolation is the dangerous one: GHC lexes `s"..."` as the
  application `s "..."`, so when an `s` is in scope it compiles clean and yields
  the literal text `a=${x}` instead of the interpolated value -- a silent
  behaviour difference, not a build failure. MicroHs-only syntax is fine in
  `bench/` and `spike/`, which GHC never compiles. A MicroHs-only *module* is
  usable from shared code only with a GHC stand-in in `test/ghc-compat/` (see
  `System.IO.TimeMilli`); GHC is not a superset of MicroHs
