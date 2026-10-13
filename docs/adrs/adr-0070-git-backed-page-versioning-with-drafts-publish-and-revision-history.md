---
id: ADR-0070
name: Git-Backed Page Versioning With Drafts, Publish, and Revision History
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0032]
---

# ADR-0070: Git-Backed Page Versioning With Drafts, Publish, and Revision History

> Status: Accepted (RFC-0032).

## Context

page content edits were unversioned -- autosave overwrote the live page
on every change, so a reader could land on a half-finished edit and there was no
way to see, compare, or restore prior content. Structural changes were versioned
only as logical intent (the operation log), not as content history. The document
tree is edited in place and imported once, so its working tree is a stable
substrate that can be a git repository.

## Decision

make the document tree a git repository in place, with a draft/publish
editing workflow on top.

- Autosave stages a per-page **draft** under a draft root outside the tree; the
  live page, its sidecar metadata, and the link index are untouched until
  publish. Editing resumes a draft; the read view marks a page that has one.
- **Publish** writes the draft through the existing publish-time path and records
  a git commit; the View/Edit toggle becomes Publish/Edit (publish exits edit
  mode). Move, delete, and restore also commit (the resulting tree state, via
  `git add -A`); a deleted page's draft is stashed into the trash entry and
  restored with it; a moved page's draft is relocated. Undo commits but does not
  maintain draft consistency (a known limitation).
- A per-page **revision history** is read from git (`git log --follow`), with a
  line-highlighted diff of any two revisions and a forward-only **rollback** (a
  new commit; history is never rewritten).
- **Author identity** is faked from a configurable request header (default
  `X-Remote-User`) with a configured default name -- no authentication -- behind
  the `Verso.Identity` seam real auth would replace. Commits pass identity via
  git's `-c user.name`/`-c user.email`, so a repository with no configured user
  still commits and attributes correctly.
- Git runs through a new framework subprocess primitive, `MicroHttp.Process`
  (`runProcess` via `fork(2)`/`execvp(3)`/`waitpid(2)`), because MicroHs's
  `System.Process` is shell-only with no argument escaping and stdout-only
  capture. Argument-vector exec makes command injection structurally impossible
  and captures stdout, stderr, and the exit code. Output uses `creat(3)` and
  `open(O_RDONLY=0)` capture files to avoid platform-divergent open flags, and
  decodes `WEXITSTATUS` (identical on macOS and Linux).
- New `VERSO_` config keys: `versioning_enabled` (default true), `draft_root`,
  `identity_header`, `identity_default`, `identity_email_domain`. When git is
  absent at startup, versioning degrades off (logged) rather than crashing.

## Consequences

git is the unified content-and-structure history; the operation
log, trash, undo, and replay-tool are retained for the import/recovery scenario
(subsuming them into git is a possible future simplification, not done here). The
`MicroHttp.Process` primitive is reusable framework infrastructure. Vocabulary
(draft, publish, revision, revision history, author identity) is recorded in
GLOSSARY.md.
