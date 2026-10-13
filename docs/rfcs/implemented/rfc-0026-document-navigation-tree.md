---
id: RFC-0026
name: Document Navigation Tree
status: Implemented
owners:
    - alistairbayley
created: 2026-06-23
updated: 2026-08-06
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# Document Navigation Tree

| Stage     | Timestamp             |
| --------- | --------------------- |
| Authored  | 2026-06-23 13:41 NZST |
| Started   | 2026-06-23 13:41 NZST |
| Completed | 2026-06-23 17:09 NZST |

## Summary

Add a left-hand **navigation tree** to the editor shell: a collapsible panel,
present in both the **read view** and **edit view**, showing the **document
tree**'s **sections** and **pages**. A disclosure control expands and collapses a
section; clicking a section's label opens its `index.md`; clicking a page opens
it. The tree is fed by a single server contract -- `GET /tree/*path` returns one
folder's immediate children as JSON -- that reads the filesystem **live** on each
request (no cached index; ADR-0059). The panel also gains **create** (new page,
new section); rename, move, and delete are deferred to a follow-up RFC. Expected
outcome: in-place browsing and authoring of the document tree without leaving the
editor, completing the third of the three planned editor panels (with the
**metadata panel** and the table of contents).

## Context

The editor serves a documentation tree in place (ADR-0045): pages are reached by
URL (`/documents/<path>.md`), with breadcrumbs (ADR-0058) the only structural
navigation. There is no way to see siblings, browse sections, or move between
pages without already knowing the URL. The **navigation tree** is the
conventional answer and the natural complement to the breadcrumb trail
(breadcrumbs are the path *up*; the tree is the structure *around and below*).

Facts established before drafting, which shape the design:

- **The tree is large.** The reference tree (`cello-docs`) holds ~3,900 pages
  across ~2,200 directories, up to 10 levels deep. Embedding the whole tree in
  every page response (the breadcrumb approach) is infeasible: ~500-700 KB of
  JSON re-sent and re-parsed per navigation, after a multi-second walk per
  request.
- **The filesystem is the source of truth, and it is mutated out-of-band.** The
  tree is a real repository the owner edits directly and reorganises with an
  external move-utility (which scans for filesystem changes, computes logical
  moves, and applies link and sidecar-metadata fixes with an undo log). Any
  server-held index would be a *cache* that drifts; a live filesystem read never
  drifts. This, with the performance analysis in ADR-0059, is why the tree reads
  live and keeps no index.
- **There is no external nav config.** No `mkdocs.yml`, no `.pages` files exist
  in the tree, so the navigation *is* the filesystem structure -- there is no
  competing source of ordering or titles to honour. Section titles come from each
  folder's `index.md` `name` (present throughout, e.g. `name: Network Delivery`),
  and ordering is the tree's own (alphabetical).
- **Every content folder has an `index.md`.** All 778 content folders (excluding
  `meta/`/`assets/`) carry one, so a **section** reliably has a title and a
  landing page; the no-`index.md` case is handled but does not arise in practice.

MicroHs feasibility for the v1 scope is already met with no new capability:
directory enumeration (`listDirectory`) compiles and runs under mhs 0.16.3.0
(probed), and **create** needs only `createDirectoryIfMissing` + `BS.writeFile`,
both already used by the save path. (The deferred rename/move/delete operations
would use `rename(2)`/`unlink(2)` -- already FFI-bound in `MicroHttp.Log` -- plus
a new `rmdir(2)`; that work belongs to the follow-up RFC.)

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- A collapsible **navigation tree** in both the read and edit views, with the
  expanded-section set, panel width, and collapsed state persisted client-side.
- One live-read server contract for folder children (`GET /tree/*path`), with the
  open page's ancestor spine embedded so the tree opens pre-expanded to it.
- **Create** a new page or section in place: title in, slug derived, seeded, and
  opened for editing.
- Reuse the existing label machinery (ADR-0058 ancestor-index titles) and
  path-safety machinery (`Static.resolveStaticPath`, `safeComponent`).

## Non-Goals

- **Rename, move, and delete** -- deferred to a follow-up RFC. All three change a
  path, so all three carry the same burden (fixing inbound links, reconciling the
  page's sidecar **meta directory**). They belong together, once the tree itself is
  proven in use. (Editing a node's *title* is already possible in-page via ADR-0057;
  the tree reflects it.) **Picked up by RFC-0027**, which implements them
  in-server (reversing the earlier external-utility plan).
- **A cached/materialised tree index** (in-memory or persisted) and the
  whole-tree search it would enable. The tree reads live (ADR-0059). An index is a
  forward-compatible future RFC behind the same endpoint if search is wanted.
- **A filesystem watcher** for out-of-band reconciliation. Not needed without an
  index; the live read is always current and the client has an explicit refresh.
- Server-side full-text search of page bodies.
- Any change to flat (non-tree) document mode; the tree is tree-mode only.
- Authentication/authorisation on the create endpoint (the server has none today;
  unchanged -- see Security).

## Proposal

### Node model and wire contract

A tree node is the unit the client renders:

```haskell
Node = { name : String      -- display label (title)
       , path : String      -- tree-relative; section: dir path, page: <path>.md
       , kind : "section" | "page"
       , hasChildren : Bool  -- section has sub-sections or non-index pages
       }
```

- `GET /tree/*path` -> JSON array of the immediate children of the folder at
  `path` (`path` empty = tree root), read live from the filesystem, obeying the
  folding/hiding/labelling/ordering rules below. This is the only read the client
  needs; it fetches it lazily when a section is expanded.

Folding / hiding / labelling / ordering (the live read applies these):

- A folder is a **section**; its label is its `index.md` frontmatter `name`
  (ADR-0058 `frontmatterTitle`), falling back to the humanised directory segment.
  `index.md` is *not* emitted as a child -- the section node *is* it; clicking a
  section opens `<dir>/index.md`.
- A `.md` file other than `index.md` is a **page**; its label is its frontmatter
  `name`, falling back to the humanised filename.
- Hidden: `meta/` and `assets/` (**peer assets** / sidecar dirs), dotfiles (e.g.
  `.DS_Store`), and non-`.md` files.
- `hasChildren` is true when a section holds at least one sub-section or one
  non-index page, so the client knows whether to draw a disclosure control.
- Order: **sections first, then pages, alphabetical by label within each group.**

Path safety: every `path` segment is validated by `safeComponent` (no
`.`/`..`/separators/NUL) before any filesystem access, exactly as
`Static.resolveStaticPath` does for `/documents`.

Labelling a folder's children requires reading each child's frontmatter `name`
on expand. At interactive fan-out this is a few tens of small reads (low tens of
milliseconds on local storage) and is amortised by the client cache below.

### Live provider (no index)

A plain module of functions implements the read; there is **no provider
abstraction or mode switch** (an index was considered and rejected, ADR-0059). The
module exposes the children-of-a-folder computation (the pure folding/ordering
over a directory listing is the testable seam) and the route wraps it.

The open page's **ancestor spine** is embedded on the editor page as
`data-tree-spine`: the child listings for each ancestor folder on the current
page's path (reusing the `linkedFolderPaths` walk from ADR-0058). The client uses
it to render the tree already expanded to the current page with zero load-time
fetches. Only sections the user expands *beyond* the spine trigger a `GET /tree`.

### Create

The one mutating operation in v1. A new page or section has no inbound links and
no existing sidecar, so the app owns it entirely -- no external-utility
involvement, and no new FFI (`createDirectoryIfMissing` + `BS.writeFile`).

- **Endpoint**: `POST /tree/*path` (mirroring the read), carrying the kind
  (`page` | `section`) and the title.
- **Eager write**: the file is written immediately, not deferred to an edit. (The
  existing seed-on-edit affordance in `treeEdit` -- a missing page shows
  `seededMarkdown` and is created on first save -- stays for following a broken
  link, but explicit create produces a real node now, which the live tree shows
  on its next read.)
- **Title in, slug out**: the author enters a *title*; the app derives a
  kebab-case **slug** for the filename and writes `name: <title>` into the
  frontmatter, matching the tree's convention (`network-delivery/` <->
  `name: Network Delivery`). The display title and slug then diverge freely
  (see GLOSSARY.md "Title vs slug"); a later title edit (ADR-0057) never renames the
  file.
- **Collision**: if the slug exists, append a numeric suffix (`foo`, `foo-2`),
  reusing the dedup pattern of `storeAsset`.
- **Seed**: a new **page** is `---\nname: <title>\n---\n\n# <title>\n`; a new
  **section** creates the directory and a seeded `index.md` of the same form.
- **After create**: open the new page in the **edit view** (`?edit`) so the
  author starts writing; the client optimistically inserts the node and the next
  tree read confirms it.

The create affordance is browser-iterated UI, not a contract: a "+" on each
section row and on the panel header (top level), revealed on hover, opening one
inline form (a title field, a page/section choice, create/cancel) under the
chosen parent. Create is available in **both** the read and edit views (creating
always opens the new page in the edit view). The panel also has a collapse-all
control, and node labels carry a full-title tooltip since deep rows truncate.

### Client

- New module `nav-tree.ts`. The testable seams are pure: `parseTreeChildren`
  (JSON -> nodes), the active-node match against `data-document`, the
  expanded-ancestor computation for the open path (from the spine), the
  title-to-slug derivation, and the label filter.
- `NavTreePanel` builds a `<nav>` of nested `<ul>`/`<li>` with a disclosure
  control per section. Expanding fetches `GET /tree/<path>` once and keeps the
  children in memory (collapse hides the DOM, it does not refetch). Successful
  reads and the embedded ancestor spine also seed a validated `sessionStorage`
  child catalogue for later pages in the same browser tab.
- A new page reads the session catalogue before its first render. The current
  page's embedded spine replaces any stored copies of its ancestor listings.
  Other persisted expanded branches render from stored children immediately,
  then check their live `GET /tree/<path>` values in parallel. Changed listings
  replace their stored rows after the checks finish. A failed check keeps the
  stored rows; a branch with no stored rows shows the existing retry state.
- The explicit refresh action clears the in-memory view and reads the root and
  every expanded branch in parallel. DOM remains lazy, so only expanded
  subtrees exist.
- Section-row interaction: the disclosure control toggles expand/collapse; the
  row label navigates to the section's `index.md`.
- Persistence in `localStorage`, mirroring `editor-mode`/theme:
  `editor-nav-expanded` (expanded section paths), `editor-nav-width`,
  `editor-nav-collapsed`.

### Layout

The panel is the **workspace's leading column** in both views: it sits below the
top bar (the Edit/View toggle and presentation controls) and the breadcrumbs --
which keep their full width -- and to the left of the editing pane, with the
metadata panel still on the right. It is a sticky flex item (it stays in view
while the pane scrolls) and collapses to just its toggle. Because the workspace is
a plain flex row in every theme, the same placement works uniformly -- no
per-theme grid surgery (an earlier full-height left-rail variant was dropped for
this position on review). Exact CSS is browser-iterated per AGENTS.md (visual work
is not strict-TDD), but the *behaviour* (present in both views, collapse/expand,
persistence, navigation, create, lazy-load error/retry) is verified.

## Alternatives Considered

- **Embed the whole tree as JSON in every page** (breadcrumb pattern): rejected
  -- infeasible at ~6,000 nodes (payload + per-request walk).
- **A cached/materialised index** (in-memory + persisted + incrementally
  maintained), giving whole-tree search and instant expand: deferred (ADR-0059).
  It is a cache of an out-of-band-mutated filesystem (drift, persistence,
  maintenance complexity), and at this tree size on local storage it buys search,
  not perceptible speed. It is forward-compatible behind the same `GET /tree`
  contract, so deferring wastes nothing.
- **A two-mode (lazy/index) provider with `auto` size-thresholding**: rejected as
  premature -- the threshold is an untunable guess guarding a tree size that does
  not exist yet, and `auto` silently changes behaviour. One live mode now; an
  index later if warranted.
- **Reuse seed-on-edit for create** (navigate to `?edit`, create on first save):
  rejected for *explicit* create -- the node would not exist (or show in the tree)
  until a save happens, and is lost on navigate-away. Kept only as the
  broken-link affordance it already is.
- **Rename/move/delete in this RFC**: deferred -- all change a path and share the
  inbound-link + sidecar-reconciliation burden and the external-utility workflow;
  grouped into their own RFC.

## Security Impact

- New read (`GET /tree/*path`) and write (`POST /tree/*path` create) surfaces.
  All paths pass `safeComponent` validation before any filesystem access, so
  traversal (literal and percent-encoded `..`, separators, NUL) is rejected
  exactly as for `/documents`.
- Create writes only within the configured tree root (the resolved-and-validated
  path); it cannot create outside it. The derived slug is constrained to safe
  characters.
- The server has no authentication today; the create endpoint inherits that
  posture. This RFC does not add auth; the server should not be exposed on an
  untrusted network without it -- a deployment constraint, not new to this RFC.

## Reliability Impact

- **Bounded client staleness.** The server still reads the filesystem live. A
  stored expanded branch can be stale during its parallel freshness check. A
  successful check replaces changed rows, while a failed check keeps the stored
  rows until a later page load or explicit refresh succeeds.
- **Create failure** (write/`createDirectoryIfMissing` error) is surfaced to the
  client and leaves the tree unchanged; a partial section create (dir made,
  `index.md` write failed) is reported rather than silently leaving an
  `index.md`-less folder.
- **Per-expand read cost** is bounded by a folder's fan-out and is below the
  perception threshold on local storage (ADR-0059); the client cache avoids
  re-reading on re-expand.

## Compatibility Impact

- Flat (non-tree) document mode is unaffected -- the tree, its routes, and its
  client panel apply only in tree mode.
- New routes under `/tree`; no change to `/documents` routes or the save path.
- **No new config keys** (the index's `navtree_mode`/cache path are not built).
- No new MicroHs capability required for v1 (create uses existing
  `createDirectoryIfMissing` + `BS.writeFile`).

## Testing and Quality Gates

- `make check` (markdownlint, fourmolu, hlint, mhs unit+integration, GHC-compat,
  editor-check) and `make editor-check` (biome, knip, tsc, vitest, bundle).
- Server (hspec, `test/unit/MicroHttp/`): children enumeration (folding
  `index.md`; hiding `meta/`/`assets/`/dotfiles/non-`.md`; label resolution;
  sections-first alpha ordering); path-safety on `/tree` and create; create
  behaviour (slug derivation, numeric-suffix collision, seed content, section
  `index.md` seeding) -- and that create touches no sidecar/links.
- Client (vitest, `test/editor/`): `parseTreeChildren`, active-node match,
  expanded-ancestor computation from the spine, title-to-slug derivation, label
  filter; panel behaviour contracts (present in both views, collapse/expand,
  persistence, section-row navigation vs disclosure, create-then-open); immediate
  rendering from the session child catalogue and parallel freshness checks that
  replace changed rows.
- Visual layout (panel placement, per-theme grid) is browser-verified via
  `preview_*`, not brittle-tested (AGENTS.md).

## Rollout Plan

1. **Phase 1 -- Read-only navigation.** (Done 2026-06-23.) Live children
   computation + `GET /tree/*path`; ancestor-spine embed; `nav-tree.ts` +
   `NavTreePanel` (lazy fetch, session cache, refresh); layout integration across
   themes (two-column grid; Workbench nav column); persistence; section-row
   navigation/disclosure. Ships usable navigation.
2. **Phase 2 -- Create.** (Done 2026-06-23.) `POST /tree/*path` (eager write,
   title->slug, numeric-suffix collision, seed, section `index.md`); create
   affordance (inline form, both views, hover-revealed "+"); optimistic reveal +
   open-in-edit. Panel also gains collapse-all and full-title tooltips.
3. **Phase 3 -- Cross-page child catalogue.** (Done 2026-08-06.) Seed a
   validated `sessionStorage` catalogue from successful reads and each embedded
   spine. Render persisted expanded branches from it before first paint, then
   check those branches in parallel and replace only changed rows.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or its design contracts do not
  cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC
  if another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- (Resolved 2026-06-23) **Root presentation**: the tree root's children are shown
  directly as the panel's top level (top-level sections plus the root's loose
  pages such as `home.md`), with no synthetic root node -- less nesting.

## Decision records

- **ADR-0059** (recorded, Proposed): the navigation tree reads the filesystem live
  with no cached index; one `GET /tree/*path` contract; section labelling/folding
  extends ADR-0058.
- The deferred rename/move/delete RFC will own the ADR for "app path-mutations
  move only the file/folder; the external utility owns inbound-link and sidecar
  reconciliation."

## GLOSSARY.md additions (recorded during grilling)

- **Section** -- a folder of the document tree, titled and landed by its
  `index.md`, which is folded into the section (not a child).
- **Navigation tree** -- the left panel in both views; disclosure expands, label
  opens the section.
- **Title vs slug** (flagged ambiguity) -- the display title (frontmatter `name`)
  and the filesystem slug/path are independent and unsynced.
