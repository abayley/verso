---
id: RFC-0032
name: Git-backed page versioning with drafts, publish, and revision history
status: Implemented
owners:
    - alistair
created: 2026-06-30
updated: 2026-06-30
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Git-backed page versioning with drafts, publish, and revision history

| Stage     | Timestamp              |
| --------- | ---------------------- |
| Authored  | 2026-06-30 10:18 NZST  |
| Started   | 2026-06-30 10:21 NZST  |
| Completed | 2026-06-30 11:40 NZST  |

## Summary

Introduce a versioning backend built on git, plus a draft/publish editing
workflow. Editing a page no longer writes the live document tree on every
autosave: autosave persists to a per-page **draft** held outside the tree. The
author promotes a draft into the tree with an explicit **Publish** action, which
performs the existing publish-time work (write page, sync sidecar metadata,
update the link index) and records the change as a git commit. Structural
operations (move, delete, restore) also commit. A page's **revision history** is
read from git: authors can list revisions with timestamps and author names, diff
any two revisions, and roll a page back to an earlier revision (as a new commit,
never a history rewrite). Author identity is faked for now by deriving a
username from a configurable HTTP request header, behind a seam that real
authentication can replace later.

## Context

The Verso wiki app edits a MkDocs-style document tree in place (ADR-045). Today
the editor autosaves the full page markdown to `POST /documents/<path>` roughly
every two seconds, and `treeSave` writes it straight into the tree, syncs image
sidecar metadata, and patches the in-memory link index. There is no record of
prior page content: an autosave silently overwrites the live page, and a reader
can land on a half-finished edit. Content edits are therefore completely
unversioned.

Structural changes are versioned, but separately and only as logical intent:
RFC-0027/0028 give an append-only operation log (move/delete/restore), a trash,
undo, and a `replay-tool` that re-applies operations onto a freshly imported
tree. None of that captures page content history, and none of it gives an author
a way to see, compare, or restore previous versions of a page's text.

Two product gaps follow. First, authors want to edit without immediately
changing what readers see, and to keep an in-progress edit across navigation.
Second, authors want a real version history per page: who changed it, when, what
changed, and the ability to go back.

Git already solves content history, diff, and rollback. The document tree is
edited in place and (per the design decision below) imported once and then
authored in place, so the working tree is a stable substrate that can be a git
repository without being clobbered by re-imports. The remaining obstacle is that
MicroHs's `System.Process` is shell-only (`libc system()`), with no argument
escaping and no combined stdout/stderr/exit-code capture; running git through it
safely would require a fragile hand-rolled quoting layer. This RFC removes that
obstacle with a small framework subprocess primitive that uses `execvp` directly.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- Autosave writes a per-page draft outside the document tree; the live page is
  unchanged until Publish.
- A draft survives navigation: returning to a page with a draft resumes editing
  that draft, and the read view marks the page as having an unpublished draft.
- Publish promotes the draft into the tree through the existing publish-time
  path and records a git commit attributed to the acting author.
- Move, delete, and restore also record git commits, so git is the unified
  content-and-structure history.
- A per-page revision history view lists revisions (short hash, timestamp,
  author, message), supports diffing any two revisions, and supports rolling a
  page back to a chosen revision as a new commit.
- Author identity is faked by deriving a username from a configurable HTTP
  header, behind a seam a real auth provider can replace without touching the
  versioning code.
- A reusable framework subprocess primitive (`MicroHttp.Process`) runs external
  commands via `execvp` with exact argument passing and full output/exit-code
  capture.

## Non-Goals

- Real authentication, accounts, passwords, or authorization. Identity is a
  display name only; anyone reaching the server is trusted (unchanged from today).
- Branching, merging, or conflict resolution. There is a single linear history
  on the default branch; last writer wins for drafts.
- Replacing or retiring the operation log, trash, undo, or `replay-tool`. They
  are retained for the import/recovery scenario; subsuming them into git is out
  of scope and noted as a future possibility only.
- Remote git (push/pull/clone), signing, or hosting integration.
- Versioning the attachment blob store. Attachment blobs are content-addressed
  and immortal, so a rolled-back page still resolves its image and asset
  references; the blobs themselves are not committed.
- Per-keystroke or per-autosave commits. Git is never on the autosave hot path.

## Proposal

### RFC-0032 Terminology

The project glossary (CONTEXT.md) reserves "history", "repo", and "corpus". This
RFC introduces user-facing version vocabulary that must be added to CONTEXT.md
when work starts:

- **Draft**: an unpublished, staged edit of a page, stored outside the document
  tree and autosaved. Not served to readers and not in git.
- **Publish**: the author action that promotes a draft into the document tree as
  a new git revision.
- **Revision**: a git commit that changed one or more pages, identified by its
  commit hash, timestamp, author, and message.
- **Revision history**: the ordered revisions affecting a page (distinct from the
  **operation log**, which the glossary already disambiguates).
- **Author identity**: a faked display name used as the git author and shown in
  revision history.
- **Git repository**: the version substrate. The logical thing remains the
  **document tree**; "repository" refers only to the git layer beneath it.

### MicroHttp.Process Framework Subprocess Primitive

MicroHs's `System.Process` runs everything through `libc system()` (a shell),
space-joins arguments with no escaping, and `readProcess` captures stdout only
and throws on non-zero exit. That is unsafe for paths with spaces and gives no
way to distinguish "nothing to commit" from a real git failure.

Add a framework module `MicroHttp.Process` (peer of `MicroHttp.FileSystem`, a
libc FFI shim) exposing one primitive:

```haskell
data ProcResult = ProcResult
    { procExit :: ExitCode    -- decoded from WEXITSTATUS
    , procOut  :: ByteString  -- captured stdout
    , procErr  :: ByteString  -- captured stderr
    }

runProcess
    :: FilePath          -- executable, PATH-resolved by execvp
    -> [String]          -- argv (argv[0] set to the executable); no shell, no quoting
    -> Maybe FilePath    -- optional working directory (chdir in the child)
    -> Maybe ByteString  -- optional stdin
    -> IO ProcResult
```

Output and stdin are `ByteString` (not `String`) for byte-exactness: page content
stays bytes (the project's UTF-8/Char8 distinction, ADR-038), so `git show` of a
page round-trips losslessly. Callers decode to text where they need it (log/diff
parsing).

Implementation (validated by spike on macOS, MicroHs 0.16.3.0):

- The parent creates stdout and stderr capture files with `creat` (avoids the
  platform-divergent `O_CREAT`/`O_TRUNC` flag values), and, when stdin is
  supplied, writes it to a temp file opened read-only with `open(path, 0)`
  (`O_RDONLY` is `0` on macOS and Linux).
- `fork`; in the child, `dup2` the capture files onto fds 1 and 2 (and the stdin
  file onto fd 0 when present), optionally `chdir`, then `execvp` with an argv
  built via `withCAString` + `withArray0 nullPtr`. The child does only
  async-signal-safe syscalls between fork and exec, and `_exit 127` if exec fails.
- The parent `waitpid`s and decodes the exit status as `WEXITSTATUS`
  (`(status >> 8) & 0xff`; identical layout on macOS and Linux), then reads the
  capture files.

Because arguments are passed as an argv vector, shell metacharacters, spaces, and
quotes reach the program verbatim and command injection is structurally
impossible (spike confirmed `$(...)`/`;` passed as literal text and not executed).

This module is framework-generic (no wiki domain), lives in `MicroHttp.*`, and is
consumed by `Verso.*` under the existing one-way dependency rule. Vendoring it
in-repo (rather than patching the MicroHs stdlib) keeps builds reproducible and
matches the established libc-shim pattern. Contributing the improvement upstream
to MicroHs later is optional and out of scope here.

### Verso.Git Git Operations Wrapper

Add `Verso.Git`, an application module wrapping git invocations on top of
`MicroHttp.Process`. All git calls use `git -C <treeRoot> <args...>` with the
tree root passed as a plain argv element. Author identity rides on git's own argv
options rather than the process environment (the `runProcess` primitive takes no
environment parameter): each commit is invoked as
`git -C <root> -c user.name=<name> -c user.email=<email> commit ...`, so no
environment plumbing is needed and every argument is still passed exactly.
Planned operations:

- `ensureRepository :: FilePath -> IO ()` — if the tree root is not already a git
  repository, `git init` it and create an initial commit of the current tree
  state ("one-time import"). If it is already a repository, use it as-is.
- `commitPaths :: FilePath -> Identity -> String -> [TreePath] -> IO CommitResult`
  — stage the given paths and commit with the author identity and message;
  detect "nothing to commit" (no staged changes) and report it distinctly from
  failure rather than erroring.
- `logForPath :: FilePath -> TreePath -> IO [Revision]` — `git log --follow
  --format=...  -- <path>`; `--follow` tracks a page across moves so history is
  continuous through structural operations.
- `diffBetween :: FilePath -> Revision -> Revision -> TreePath -> IO String` —
  `git diff <from> <to> -- <path>`.
- `showFileAtRevision :: FilePath -> Revision -> TreePath -> IO ByteString` —
  `git show <rev>:<path>`; used by rollback.

`CommitResult` distinguishes committed (with new hash), nothing-to-commit, and
failure. `Revision` carries short hash, full hash, ISO timestamp, author name,
and subject.

### Draft Staging

Add a `draft_root` config key (default `data/drafts`), outside the served tree.
A draft for tree path `a/b/page.md` is stored at `data/drafts/a/b/page.md`. Being
outside the tree, drafts are never served, never walked by the link index, and
never appear in git status.

Autosave path change (`treeSave`): when versioning is enabled, the autosave POST
writes the markdown to the draft path only. It does not write the tree, does not
run `syncImageTitles`, and does not update the link index. Those are derived from
published content and are deferred to Publish, which keeps autosave cheap and
keeps the live page and link graph consistent with what readers see. The save
status fragment returned to the editor is unchanged.

Edit path change (`treeEdit`, `?edit`): load the draft if one exists for the
path; otherwise load the published page content (current behaviour). The editor
is told it is editing a draft so the UI can reflect it.

Read path change (`treeRead`): always shows published content. If a draft exists
for the page, the read view marks it (see UI below).

### Author Identity (Faked)

Add `Verso.Identity` exposing `currentIdentity :: RequestHead -> Identity`. It
derives the author name from a configurable request header (`identity_header`,
default `X-Remote-User` -- the de-facto header reverse-proxy auth sets), falling
back to a configured default name (`identity_default`, default `anonymous`) when
the header is absent. No prompt, no cookie, no password: identity is whatever the
header carries. The email used for git is synthesised deterministically from the
name (for example `<slug>@<identity_email_domain>`). This module is the single
seam where real authentication slots in later: a future auth middleware (or the
existing reverse proxy) sets the header, or `currentIdentity` is reimplemented to
read a session -- without touching any versioning code. Identity is a label only;
no authorization decision depends on it.

### Publish Flow

The View/Edit toggle becomes a Publish/Edit toggle: in read mode the control
reads "Edit" (enters edit mode); in edit mode the controls are "Publish" and
"Cancel". Publish commits the draft and returns to read mode. Cancel (after a
confirm) discards the draft via `?discard-draft` so the page reverts to its last
published version, and returns to read mode. Either control leaves edit mode;
navigating away without using either keeps the draft for next time.

Add an explicit publish action. Endpoint: `POST /documents/<path>?publish` (a
form POST, since it mutates). Behaviour:

1. Resolve the author identity from the request via `currentIdentity` (always
   succeeds: header value or the configured default). No prompt.
2. Read the draft for the path. If there is no draft, report nothing to publish.
3. Run the existing publish-time path against the tree: `writeDocumentText`,
   `syncImageTitles`, and the `onSave` link-index update.
4. `commitPaths` the page (and any sidecar metadata paths it touched) with the
   author identity and an auto-generated commit message (for example the page's
   first heading, falling back to the tree path). Authors never supply commit
   messages.
5. If the commit reports nothing-to-commit (draft identical to published
   content), skip the commit and report "no changes" rather than creating an
   empty revision.
6. Delete the draft.
7. Redirect to the read view, which now shows published content with no draft
   marker.

A discard action (`POST /documents/<path>?discard-draft`) deletes the draft
without publishing and returns to the read view.

### Structural Operation Commits

After a move, delete, or restore applies to the tree and appends to the operation
log (unchanged RFC-0027/0028 behaviour), the handler also commits the affected
tree paths via `commitPaths` with the acting identity and a message describing
the operation. Because `logForPath` uses `--follow`, a page's revision history
remains continuous across a move. The operation log and trash are retained
unchanged for the import/recovery and undo scenarios.

When a page that has an unpublished draft is moved or deleted by a structural
operation, the draft becomes stale relative to its tree-path key. The structural
handlers must keep drafts consistent: a move renames the corresponding draft
file; a delete moves the draft into the page's trash entry (recoverable),
alongside the page's other trashed content, and restore brings the draft back
with the page. This is a required edge case, not optional.

### Revision History View

Replace the metadata pane's attachments-only content with an added **Revision
history** link (the pane sits below the table of contents and currently shows
attachments). The link targets a per-page history view.

The history view is a standalone page that reuses the editor's theme head (the
`wa-` palette classes, `data-editor-theme`, the theme-bootstrap script, and both
stylesheets) so it matches the editor/reader look. It loads the editor bundle and
renders the editor's own theme and appearance (light/dark/match-system) controls
-- the same Web Awesome `wa-dropdown` and icon `wa-radio-group`, in a matching top
toolbar -- wired to the same `localStorage` keys the editor uses (choices carry
over both ways).

History view: `GET /documents/<path>?history` renders the page's revisions
(timestamp, author, subject + short hash), newest first, from `logForPath`, in a
fixed-height scrollable table with a sticky header. Each row has a select
checkbox, and its timestamp links to that revision in the read-only view
(`?at=<rev>`). The view supports:

- **View a past revision**: `GET /documents/<path>?at=<rev>` renders the
  read-only editor over the page's content at that revision (`showFileAtRevision`).
  Assets resolve against the current tree, so an asset removed since then is
  missing -- an accepted limitation.
- **Diff two revisions**: tick two rows (a small inline script limits selection to
  two and enables the Compare button only when exactly two are picked), then
  Compare fetches `GET /documents/<path>?diff&pane&from=<rev>&to=<rev>` -- a bare
  HTML fragment -- and injects it into a diff pane below the table (no page
  reload). The diff is rendered **side-by-side**: context lines on both sides,
  removed lines left and added lines right (paired positionally within a change
  block), parsed from git's unified diff. The full-page `?diff` (without `pane`)
  remains for a direct link.
- **Roll back to a revision**: select one row, then `POST
  /documents/<path>?rollback&rev=<rev>`. Rollback reads the page content at that
  revision via `showFileAtRevision`, writes it through the publish-time path
  (tree write, sidecar sync, index update), and commits it as a new revision
  (`Roll back <path> to <short-hash>`). History is never rewritten; rollback is
  forward-only.

### Configuration Keys

New `VERSO_`-scoped keys (per the RFC-0030 config split), all with safe defaults:

- `versioning_enabled` (bool, default true): master switch. When off, the app
  behaves as today (autosave writes the tree directly; no drafts, no git).
- `link_index_enabled` (bool, default true): when off, the RFC-0029 link index is
  not opened at startup and move/delete use the byte-scan fallback. An escape
  hatch for environments where opening the index misbehaves.
- `draft_root` (string, default `data/drafts`): draft staging directory.
- `identity_header` (string, default `X-Remote-User`): request header the author
  name is read from.
- `identity_default` (string, default `anonymous`): author name used when the
  header is absent.
- `identity_email_domain` (string, default `verso.local`): domain for synthesised
  git author emails.

Startup: when `versioning_enabled`, verify `git` is invokable (`git --version`
via `runProcess`) and `ensureRepository` the tree root. If git is unavailable,
log a clear error and disable versioning for the session rather than crashing the
server.

### Edge Cases And Invariants

- Tree already a git repository: use it; do not re-init or force an import commit.
- Publish of an unchanged draft: no commit, reported as no changes.
- Page path with spaces or unusual characters: handled by argv exec; no quoting.
- Draft for a moved/deleted page: relocated by a move; moved into the trash entry
  by a delete and restored with the page.
- `git` missing at runtime: versioning disabled for the session, logged.
- Concurrency: single-user assumption holds; draft writes are last-writer-wins.

## Alternatives Considered

- **Git as a shadow repository alongside an untouched tree**: rejected. The tree
  is imported once and then authored in place, so the working tree is a safe git
  substrate; an in-place repository makes diff and rollback operate on the real
  files and avoids keeping two stores consistent.
- **Re-export-driven corpus with git committing each re-export**: not applicable;
  the chosen workflow is one-time import then in-place authoring, so there is no
  recurring re-export to generate noisy commits.
- **Hand-rolled shell quoting over MicroHs `System.Process`**: rejected. It
  leaves an injection/correctness surface, cannot capture stderr, and cannot
  cleanly separate "nothing to commit" from failure. The `execvp` primitive
  removes the entire problem class for modest, well-bounded FFI.
- **Patching MicroHs's `System.Process` upstream instead of vendoring**:
  rejected as the primary path. It couples app correctness to a locally-patched
  compiler stdlib and breaks reproducible builds; vendoring matches the existing
  libc-shim architecture. Upstreaming later is welcome but not a dependency.
- **Subsuming the operation log/trash/undo into git now**: deferred. It is a
  larger change with its own risks; git and the operation log coexist for this
  RFC, with unification noted only as a future possibility.
- **`posix_spawn` instead of `fork`/`execvp`**: rejected for the first cut. It
  requires FFI over opaque `posix_spawn_file_actions_t`/`posix_spawnattr_t`
  structs whose layout differs by platform (the rfc-0007 struct-layout hazard),
  whereas `fork`/`execvp`/`waitpid`/`dup2` use only ints and pointers.

## Security Impact

- Command injection: structurally prevented by argv-based `execvp` (no shell).
  The spike confirmed shell metacharacters in arguments are passed literally.
- Identity is faked and unauthenticated; this RFC does not change the trust model
  (the server is already a trusted single-user tool with "no user identity"). The
  identity header is client-spoofable unless a trusted reverse proxy sets it, but
  no authorization decision depends on it; it only labels commits and history.
  When real auth arrives it owns the header (or replaces `currentIdentity`).
- Drafts live outside the served tree and are never served, so staged content is
  not exposed through the document routes.
- Author email is synthesised, not collected, so no personal data is introduced.

## Reliability Impact

- Autosave no longer mutates the live tree or the link index, removing the
  half-finished-edit-visible-to-readers failure mode and reducing autosave work.
- Publish performs a tree write, sidecar sync, index update, and a git commit in
  sequence. If the commit fails after the tree write, the tree and index are
  already updated but uncommitted; this is recoverable (the next publish or a
  manual commit captures it) and must be logged. Ordering and failure handling
  are part of the publish implementation contract.
- `git` invocations are off the autosave hot path; they occur on publish,
  structural operations, and on-demand history/diff/rollback, so subprocess
  overhead does not affect typing latency.
- Git unavailability degrades to versioning-disabled with a clear log, not a
  crash.
- Rollback is forward-only (a new commit), so history is never rewritten and
  recovery from a bad rollback is another rollback.
- `MicroHttp.Process` uses temp capture files (no pipe-deadlock risk) and reaps
  children with `waitpid` (no zombies).
- Connection-level failures (read/parse/write or idle-timeout errors that occur
  before or outside the application stack) are now logged to stderr by the server
  rather than silently discarded, so stalled or failing connections are visible
  in the logs. A total runtime event-manager wedge (the read never returns and
  the idle timer never fires) remains an environmental fault that cannot be
  self-reported from inside the frozen runtime.

## Compatibility Impact

- Internal: `treeSave`, `treeEdit`, `treeRead`, and the structural handlers
  change behaviour when `versioning_enabled`. With the flag off, behaviour is as
  today, giving a clean fallback.
- The View/Edit toggle becomes Publish/Edit (see UI), changing the editor chrome
  contract; the read view gains a draft marker and a revision-history link.
- New routes/query flags: `?publish`, `?discard-draft`, `?history`, `?diff`,
  `?rollback`. Existing routes are unchanged.
- New config keys are additive with safe defaults; existing configs keep working.
- The operation log, trash, undo, and `replay-tool` are unchanged.
- New framework module `MicroHttp.Process`; new app modules `Verso.Git` and
  `Verso.Identity`. All follow the qualified-import and Haddock conventions
  (ADR-069).

## Testing and Quality Gates

- `make format` then `make clean && make check` (clean build is mandatory after
  structural edits; incremental `make check` masks export-list breakage per the
  RFC-0031 cache gotcha), plus explicit compile of `build/verso` and
  `build/replay-tool`.
- `MicroHttp.Process` unit/integration tests: run `/bin/echo` capturing stdout;
  a command writing to stderr; a non-zero exit (`/usr/bin/false`); an argument
  containing spaces and shell metacharacters asserted to arrive verbatim and not
  be executed; stdin delivery; a working-directory run.
- `Verso.Git` integration tests against a temporary git repository: init +
  import commit; commit a path and read it back via `logForPath`;
  nothing-to-commit detection; diff between two revisions; `showFileAtRevision`;
  `--follow` continuity across a move.
- Draft behaviour: autosave writes the draft and leaves the tree and link index
  unchanged with no commit created; edit resumes the draft over published
  content; read view marks a page with a draft and does not mark one without.
- Publish behaviour: tree updated, sidecar synced, index updated, exactly one new
  revision attributed to the author, draft cleared, marker gone; publishing an
  unchanged draft creates no revision.
- Structural-op commits: move/delete/restore each add a revision; `--follow`
  tracks a page across a move; a draft is relocated on move, moved into the trash
  entry on delete, and restored with the page.
- Rollback: restores earlier content into the tree and adds a new revision;
  history grows and is not rewritten.
- Identity: header value used as author; configured default when header absent;
  deterministic email synthesis from the name.

## Rollout Plan

Phases are completed as committed green slices (the order is pragmatic, not
strictly sequential: the configuration-agnostic backend slices land first, the
browser-driven editor/visual slices follow).

- [x] Phase 0 — `MicroHttp.Process` framework primitive (`runProcess`,
  `ProcResult`) with its test suite. No app behaviour change.
- [x] Phase 1 — `Verso.Git` wrapper (`ensureRepository`, `commitPaths`,
  `logForPath`, `gitAvailable`), integration-tested against a real repository.
- [x] Phase 3 — `Verso.Identity` header-derived identity with a configured
  default, and the five `VERSO_` config keys.
- [x] Phase 2 — Draft staging: `Verso.Draft` store, autosave-to-draft,
  edit-resumes-draft, the read-view "(unpublished draft)" marker, and the startup
  git check + import commit behind `versioning_enabled`.
- [x] Phase 4 — Publish flow (commit on publish via `commitPaths`), discard-draft,
  and the Publish/Edit chrome replacing View/Edit. Verified end-to-end in the
  browser against a scratch versioned tree (publish writes + commits + clears the
  draft + returns to the read view; marker appears/clears correctly).
- [x] Phase 5 — Structural-operation commits (move/delete/restore/undo commit
  the resulting tree state via `commitAll`) and draft consistency: a move
  relocates the page's draft, a delete stashes it into the trash entry and
  restore brings it back. (Draft consistency through undo is a known gap.)
- [x] Phase 6 — Revision history view (`?history`, lists revisions with a
  compare form and per-row roll-back), line-highlighted diff of two revisions
  (`?diff`), rollback as a new forward-only commit (`?rollback`), and a
  "Revision history" link in the metadata pane. Backend covered by integration
  tests (history returns the revision list; rollback reverts content and commits
  "Roll back ..."); the standalone history/diff pages are server-rendered HTML.
- [x] Phase 7 — CONTEXT.md glossary additions (draft, publish, revision,
  revision history, author identity) and ADR-070 (covering the in-place-git
  decision, the draft/publish workflow, identity, and the `MicroHttp.Process`
  subprocess primitive).

### Rollout Plan Escape Hatch

- If implementation reaches behaviour that this RFC or its design contracts do
  not cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning
  RFC if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

None outstanding. The initial design questions were resolved (2026-06-30) and
folded into the Proposal:

- Commit messages are always auto-generated; authors never supply them.
- Diffs use word/line-level highlighting from the first cut, not a raw
  unified-diff dump.
- Author identity is derived from a configurable HTTP header
  (`identity_header`, default `X-Remote-User`) with a configured default name;
  no cookie, no prompt. Real auth replaces this seam later.
- The operation log, trash, undo, and `replay-tool` remain separate from git for
  now; git does not subsume them in this RFC.
