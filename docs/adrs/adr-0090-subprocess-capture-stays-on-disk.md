---
id: ADR-0090
name: Subprocess capture stays on disk when its destination is a file or a response
status: Accepted
owners:
    - Alistair Bayley
created: 2026-09-12
updated: 2026-09-12
supersedes: []
superseded_by: null
related_rfcs: [RFC-0032, RFC-0040]
---

# ADR-0090: Subprocess capture stays on disk when its destination is a file or a response

## Context

`Process.runProcess` spawns a git subprocess with its stdout and stderr redirected to temporary capture
files, waits, and then reads both files whole into `ByteString`s (ADR-0038, RFC-0032). That is right for the
many small commands -- `git log`, `git commit`, `git rev-parse`, `git --version` -- whose output is a line or
two. It is wrong for the commands whose output is a whole document: `git show <rev>:<path>` captures a page's
bytes at a revision, and `git diff` a page's changes. RFC-0040 made the read and write paths constant-space,
and reading a captured document back into the heap only to write it to another file (rollback) or to escape
it into a page (viewing a revision) reintroduces exactly the whole-document copy the rest of the RFC removed.
The captured bytes already exist on disk, in the capture file; reading them into the heap is redundant work.

## Decision

`Process` offers a second entry point, `runProcessCaptured`, that leaves the child's stdout and stderr in
their capture files and returns the paths (`ProcCapture` with `captureExit`, `captureOut`, `captureErr`)
rather than reading them. The caller owns the two files and removes them with `Process.removeCapture` once it
has consumed them -- by streaming or renaming the stdout capture into place. `runProcess` is now this entry
point followed by reading and removing the files, so the small-command path is unchanged. `spawnCapturing`
holds the shared spawn-and-wait, and on a spawn failure writes its message to the stderr capture and returns
exit 127, so both entry points report the failure the same way.

`Git.showFileAtRevisionCaptured` runs `git show <rev>:<path>` through it. `treeRollback` streams that capture
into the live file with `Stream.copyFile` (a fixed buffer, never the whole document) and then commits;
`treeReadAt` streams it as the document through `documentTempFileResponse`, which counts the escaped length,
serves it as a sized stream (ADR-0089), and removes the capture when the body finishes
(`Stream.transformedTempFileBody`). Both read only the leading frontmatter block (`Frontmatter.readBlock`)
from the capture for the title and breadcrumbs. `git show`'s exit code, read from `captureExit`, distinguishes
a path that did not exist at the revision from an empty one. The byte-returning `Git.showFileAtRevision`
stays for tests that assert on committed content.

## Why

- The rollback and view-at-revision paths no longer route a document through the heap: the capture is streamed
  from disk in a fixed buffer, matching the constant-space property the rest of RFC-0040 established. For the
  largest corpus document (263KB) this removes a whole-document `ByteString` from each such request.
- The capture files already exist, so returning their paths is strictly less work than reading them; the
  small-command path keeps its bytes-returning shape and is unaffected (`runProcess` is unchanged behaviour).
- Ownership is explicit: the caller removes the capture, or hands it to a producer that removes it when the
  body finishes, on the same resource-release path as the file handle's close, so a client that disconnects
  mid-stream still cleans up.

## Reopens when

A capture whose destination is neither a file nor a streamed response -- some future command whose output
must be parsed into a value -- keeps using `runProcess`. `treeDiff` is such a case today: its output is
rendered side-by-side into HTML rather than served or copied, so it stays on the byte-returning path (see the
RFC-0040 phase-5 note); if diffs ever become corpus-scale this decision extends to a streamed line parser.

## Consequences

- `runProcessCaptured` hands the caller two files it must remove; forgetting to leaks a temp file. The
  document response path removes the stdout capture when the body finishes and the caller removes the stderr
  capture; a client that never reads the body leaves the temp capture until process exit, the same weak spot
  every temp-then-serve path has.
- Rollback restores across a device boundary safely: the capture lives in the system temp directory and the
  tree elsewhere, so it is copied (streamed), not renamed, avoiding a cross-device rename failure.
