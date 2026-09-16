---
id: ADR-0093
name: Git Operations Surface Failures As Typed Results
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs:
    - RFC-0032
    - RFC-0048
---

# ADR-0093: Git Operations Surface Failures As Typed Results

## Context

The git layer (`Verso.Git`, RFC-0032) sets up and commits the document-tree
repository. Some operations discarded the results of the git invocations they
ran: `ensureRepository` threw away the exit of `git init`, so a failed init still
returned `Initialised` and the server ran on a repository that did not exist, with
every later publish failing silently; `commitPaths` ignored each `git add`, so a
staging failure was not seen before the commit. This is the opposite of the
codebase's convention for fallible operations (ADR-0009, `Either` at the socket
boundary).

## Decision

A fallible git operation returns a typed result and its caller logs or acts on a
failure; none is discarded. `ensureRepository` returns `IO (Either String
RepoInit)`, `Left` carrying the captured stderr when `git init` fails.
`commitPaths` returns `CommitFailed` with the stderr when staging a path fails,
rather than committing past it. A failed structural or publish commit is logged to
stderr, not swallowed.

`logForPath` is the deliberate exception: its one caller renders the same
empty-state history page whether the command failed or the page has no history, so
it keeps returning `[]` and is not widened to a result type with no consumer.

## Consequences

A broken versioning setup is visible in the startup log rather than masquerading as
success. The git module stays configuration-agnostic: it returns the failure as a
value and the caller (which holds the logger) reports it. Reopens if a caller needs
to distinguish `logForPath`'s failure from an empty history, at which point that
function gains a result type too.
