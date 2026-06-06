# Project Coding Standards

- unit tests do no I/O, integration tests do I/O
- fully qualified imports with module aliases
- linting with hlint, format with fourmolu
- markdown validated with markdownlint
- tests do not produce filesystem artefacts in arbitrary locations, like the
  project root; they write to a temp dir
- always prefer Either over exceptions
