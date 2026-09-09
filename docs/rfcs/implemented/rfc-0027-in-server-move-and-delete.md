---
id: RFC-0027
name: In-Server Move and Delete
status: Implemented
owners:
    - alistairbayley
created: 2026-06-23
updated: 2026-06-23
supersedes: []
superseded_by: null
---

<!-- Filename must be: rfc-<4-digit-id>-<short-kebab-title>.md -->

# In-Server Move and Delete

| Stage     | Timestamp        |
|-----------|------------------|
| Authored  | 2026-06-23       |
| Started   | 2026-06-23       |
| Completed | 2026-06-24       |

## Summary

Add **move** (relocate/rename) and **delete** for **pages** and **sections** to
the navigation tree (RFC-0026), implemented entirely in the server -- no external
tool. The server preserves link integrity: when a page or section moves, it
rewrites the relative Markdown links across the tree (both the links pointing *at*
the moved item and the moved item's own outward links), maintains the parent
index.md listings (the entry moves from the source listing to the
destination's), co-moves the page's **sidecar metadata**, and relocates or copies
the page's **peer assets** by a shared/exclusive analysis. Delete is refused while other pages still link to the
target, listing the referrers so the author resolves them first. Operations are
preview-then-confirm (the impact is shown before anything is written); recovery --
an operation log, replay, undo, and a trash deletes move to -- is layered on by
RFC-0028. Expected outcome: a tree the author can reorganise and prune in place
without leaving dangling links, replacing the external move-utility.

## Context

RFC-0026 added the navigation tree with create, and **deferred** rename/move/delete
to a follow-up RFC on the assumption an external move-utility would own link and
sidecar reconciliation. That decision is now reversed: move and delete are to be
**in-server**. This RFC owns that contract and supersedes RFC-0026's
"rename/move/delete deferred / external utility reconciles" non-goal.

The corpus was surveyed to ground the design:

- **Links are relative Markdown**, throughout: `[text](./foo/index.md)`,
  `[text](../bar/x.md)`, and page-relative `assets/<name>` (~10,800 asset refs,
  ~5,600 inline `.md` links of which ~1,200 cross a directory with `../`). There
  are **no absolute links**, and **no cross-page reference-style or raw-HTML
  links** (the 58 `[id]:` matches are 3 external `https:` defs plus ~55 legend
  lines like `[C]: Configure ...`; the one raw `<a href>` is an external link
  inside a quoted HTML example). So the rewriter only needs inline `[text](target)`
  / `![alt](target)` links and relative `assets/` refs to cover 100% of the
  in-tree links.
- **Pages are mostly flat files sharing a folder's one `assets/`**: 778
  `index.md` vs 3,140 non-index pages; folders hold up to ~45 sibling pages, all
  referencing the same `assets/` directory. So moving a *section* (folder) is
  clean -- one `rename(2)` carries its pages, `assets/`, `meta/`, and subfolders,
  and only links crossing the folder boundary need rewriting -- but moving a
  single page across folders must reason about which of its assets are shared with
  siblings.
- **The served tree is gitignored** (the git root is the parent workspace, which
  excludes `cello-docs-work`), so **git is not an undo net**. Destructive
  operations have no recovery short of a backup until the planned versioning store
  exists.

MicroHs feasibility: `rename(2)` and `unlink(2)` are already FFI-bound in
`MicroHttp.Log`; only `rmdir(2)` is new (one further `foreign import ccall`).
Directory enumeration (`listDirectory`) and `BS.readFile`/`writeFile` are
available and already used.

## Phase Item Completion Instructions

Update this plan document as you go. When an item is complete, immediately mark
it as complete in the phase checklist.

## Goals

- Move (relocate to a new parent and/or rename the slug) **sections** and
  **pages**, preserving all relative link and asset integrity.
- Delete **pages** and **sections**, refusing while inbound links exist and
  listing the referrers.
- A pure, well-tested link engine: parse, resolve, find inbound links, and rewrite
  relative `.md` and `assets/` links between two tree locations.
- Co-move the page's sidecar **meta directory** on move; remove it on delete.
- Maintain parent index.md listings on move: remove the moved item's
  entry from the source listing and add it to the destination's (pages as bullets,
  sections as grid cards), synthesising a minimal entry where needed.
- Sidecar-driven shared/exclusive **asset analysis** for cross-folder page moves:
  relocate exclusive assets, copy shared ones.
- Preview-then-confirm every operation (the full impact shown before any write);
  recovery (undo, restore, replay) is layered on by RFC-0028.

## Non-Goals

- **Undo, operation log, replay, and trash.** Owned by **RFC-0028**: this RFC's
  move/delete emit the log entries and route deletes to RFC-0028's trash, but the
  journal/replay/undo/trash machinery is designed there. Content history /
  git-based versioning remains future work beyond both.
- **An external move-utility.** Reconciliation is in-server (this RFC); the tracker
  tool is no longer in the loop.
- **Rewriting non-existent link forms.** Reference-style and raw-HTML links are not
  rewritten because the corpus has none that point in-tree (they are left
  untouched and noted in the impact summary if encountered).
- **Drag-and-drop** as the move gesture (a destination picker is the v1 UX;
  drag-drop is a possible later enhancement).
- **Cross-tree or external-link fixing.** Only in-tree relative links and
  `assets/` refs are touched; `https:`/`mailto:` and the like are left alone.

## Proposal

### The link engine (pure core)

The heart is a pure, unit-tested module (no IO) over Markdown text and tree paths:

- `pageLinks :: PageText -> [Link]` -- extract inline link/image targets
  (`[text](target)`, `![alt](target)`), ignoring fenced code and the non-matching
  forms. Each `Link` keeps its byte span for surgical rewriting.
- `resolveTarget :: DirPath -> RawTarget -> Maybe TreePath` -- resolve a relative
  target against the linking page's directory to a tree-absolute path; `Nothing`
  for external (`https:`, `mailto:`, `#anchor`) or unresolvable targets.
- `inboundTo :: TreePath {- moved/deleted -} -> [(PagePath, Link)] -> [...]` --
  which links across the tree resolve to the target (or into a moved subtree).
- `relativeBetween :: DirPath -> TreePath -> RawTarget` -- the relative target to
  write from a linking page's directory to a (new) tree path; the inverse used to
  rewrite both inbound links and the moved page's own outward links.
- `rewriteLinks :: PageText -> [(span, newTarget)] -> PageText` -- apply rewrites
  by span, preserving everything else byte-for-byte (the ADR-0049 minimal-byte
  spirit).

This core is where the correctness lives and is tested exhaustively (same-dir,
`../` chains, `./` prefixes, index-vs-page targets, anchors/queries on targets,
external targets left alone, code-fence exclusion).

### Move

`POST /tree/<path>?move` with the destination parent and (optional) new slug.
A move is computed wholly against the current tree, previewed, then applied.

The link rewrite is **general**, not boundary-special-cased: build the old->new
tree-path map for every file the move relocates (the moved item, and -- for a
section -- every file in its subtree), then re-resolve *every* link in *every* page
(outside *and* inside the moved subtree) against the **old** tree and rewrite those
whose resolved target moved. A pure move leaves intra-subtree links untouched
(their relative target is unchanged); a move that also renames the slug
additionally fixes internal links that route through the old name (`../<oldname>/`).
Inbound and outbound "boundary" links are then just the common case, not the rule.

- **Section move** (`<dir>` -> `<newparent>/<slug>`): one `rename(2)` of the
  directory carries pages, `assets/`, `meta/`, subfolders; the general rewrite above
  fixes every link whose target moved.
- **Page rename** (same folder, new slug): `rename(2)` the `.md` and its meta
  directory (`<dir>/meta/<base>.meta`); assets are unaffected (same folder); the
  general rewrite fixes inbound links to the new slug (the page's own same-dir links
  are naturally unchanged).
- **Page move** (cross-folder): `rename(2)` the `.md`; co-move the meta directory;
  run the asset analysis (below); the general rewrite fixes the moved page's outward
  links, its `assets/` refs for the new directory, and inbound links to it.
- **Slug collision** at the destination: the move is **refused** with a clear
  message; the move dialog's slug field lets the author choose a different slug and
  retry (no silent rename of a deliberately-moved item, unlike create's suffixing).
- **Refusals**: a section cannot move into itself or its own descendant (a cycle),
  and the **root** section cannot be moved or deleted (it has no parent); the nav
  tree omits those actions on the root.

Every move also co-moves the moved item's sidecar **meta directory** and updates
the parent listings (both below).

#### Parent index.md listing maintenance

A folder's `index.md` lists its members: **subsections** as `grid cards`
(`- :icon: __[Title](./child/index.md)__` + a description span) and **flat pages**
as plain bullets (`- [Title](./page.md)`). Both a page move and a section move
update these listings:

- **Source parent index.md**: remove the moved item's list entry (the whole
  Markdown list item -- the bullet for a page, the card block for a section).
- **Destination parent index.md**: add that entry to its listing. The whole entry
  is **relocated** (carrying a section card's icon and description), appended to the
  destination's existing listing of the same kind. Because the entry's link is
  `./slug/...` relative to *either* parent, it relocates **verbatim** on a plain
  move; only a simultaneous rename changes the path. If the source had no entry, or
  the destination has no listing, a **minimal** entry is synthesised (title from the
  item's `index.md` `name`/frontmatter; a plain bullet, or a card without icon for a
  section) and a listing created if absent.
- These two parent `index.md` files are handled here (remove/add); they are
  **excluded from the generic inbound rewrite** so their entry is not merely
  repointed. Every *other* reference to the moved item (prose links anywhere,
  including unrelated `index.md`) is repaired by the link engine.

#### Asset analysis (cross-folder page move)

The moving page references a set of assets -- the union of its body `assets/<name>`
refs and its sidecar `images.yaml`/`attachments.yaml` entries (so an unlinked
attachment counts and travels with the page). Ownership is a **folder-wide**
question -- the `assets/` folder is shared by every page at that level -- so each
asset is classified by scanning *all* peer pages' bodies and sidecars
(an **exclusive asset** vs a **shared asset**, CONTEXT.md):

- **Exclusive** (no other page in the source folder references it, by body or
  sidecar): **relocate** to the destination `assets/` (removed from the source).
- **Shared** (any sibling references it, by body or sidecar): **copy** to the
  destination `assets/` (the source copy stays, so siblings keep working).

Either way the moved page's links become `assets/<name>` in the new folder.
Destination asset-name collisions dedup by content (reuse `storeAsset`'s rule).
The moved page's sidecar asset entries move with it; siblings' sidecars are
untouched.

### Delete

`POST /tree/<path>?delete`. The target's entry in its parent's **index.md listing**
is removed as part of the delete (the same membership reconciliation a move does),
so it is **never** counted as a blocking reference -- otherwise nothing would be
deletable, since every item's parent lists it. The *other* inbound links are then
computed:

- **If any other page links to the target** (for a section, any page *outside* the
  subtree links into it -- excluding the parent listing entry): the delete is
  **refused**, returning the referrers (page path + link text) so the client can
  show "resolve these first".
- **Otherwise** the target is moved to **trash** (RFC-0028) rather than destroyed,
  so the delete is recoverable:
  - **Page**: remove its parent index.md listing bullet; move the `.md`, its sidecar
    meta directory, and its **exclusive** assets (shared assets stay) to trash with a
    provenance record.
  - **Section**: remove its parent index.md listing card; move the whole folder
    (its pages, `meta/`, `assets/`, subtree) to trash, after the
    no-other-inbound-links check over the whole subtree.

The destruction is routed to RFC-0028's trash; this RFC supplies the listing
removal, the referrer check, and the exclusive-asset selection. `rmdir(2)` (the one
new FFI binding) is used by trash/restore and by any eventual hard purge.

### FileOps module

The three libc bindings are consolidated in a new `MicroHttp.FileOps`
(`rename`/`unlink`/`rmdir`, return codes checked -- unlike `Log`, which discards
them); `MicroHttp.Log` imports rename/unlink from there. Path inputs pass the
existing `safeComponent` validation before any FFI call.

### Safety: preview-then-confirm

The tree is gitignored, so every operation is **two-step**: the client requests a
**preview** (or the endpoint computes a dry run) that returns the complete impact --
files whose links will change, assets to relocate/copy, the meta-dir move, the
files/dirs to remove -- and applies only on explicit confirm. A move/delete is
**best-effort transactional**: all rewrites are computed up front; on a mid-apply
failure the server reports what changed (it cannot roll back). Recovery proper --
undo via inverse operations, restore from trash, and replay onto a refreshed
corpus -- is provided by RFC-0028's operation log and trash.

### Client (UX)

Per-node actions in the nav tree (RFC-0026), browser-iterated:

- **Rename** -- inline slug edit (a same-folder move).
- **Move…** -- a destination picker (the tree as a chooser); not drag-drop in v1.
- **Delete** -- a confirm dialog; on refusal, the referrer list is shown.

Each shows the server's impact preview before applying. Errors surface in the
standard notice area (RFC-0026).

### Performance

Finding inbound links (and the files a move must rewrite) needs every page, but
**parsing** all ~3,900 pages' links on each operation is far too slow on the real
corpus (~86s observed, with large link-dense pages). The scan therefore reads each
`.md` as raw bytes and only unpacks and link-parses a page when its bytes contain
the target's **name** -- the slug or filename that any relative link to it must
contain -- plus the moved subtree's own pages (which need rewriting regardless). The
byte pre-filter never drops a real referrer (false positives only cost a parse), and
brings the same operation to ~3.5s (dominated by the unavoidable read of every
`.md`, since there is no index -- ADR-0059). A persisted index remains a later
optimisation, not v1.

## Alternatives Considered

- **Keep the external move-utility** (RFC-0026's plan): rejected by the owner -- the
  reconciliation is wanted in-server so the tracker can be retired.
- **Rely on git for undo**: not available -- the served tree is gitignored, so
  there is no git history to revert. Hence preview-then-confirm here, with recovery
  via RFC-0028's operation log and trash (and a versioning store later still).
- **Move single pages by copying *all* referenced assets**: rejected -- duplicates
  assets shared with siblings; the shared/exclusive analysis copies only what must
  be copied and relocates the rest.
- **Move shared assets too** (literal "move them"): rejected -- removing a shared
  asset breaks the sibling pages that reference it.
- **Delete with link unwrapping or dangling links**: rejected for v1 -- refusing
  and listing referrers keeps the tree link-clean and is reversible by the author;
  destructive link edits with no undo are too risky here.
- **Rewrite all link forms** (reference-style, raw HTML): unnecessary -- the corpus
  has no in-tree links in those forms.

## Security Impact

- New write surface (`?move`, `?delete` under `/tree`). All paths -- source,
  destination, and every rewritten/removed file -- pass `safeComponent` validation
  before any FFI/`writeFile`/`unlink`/`rmdir`, so operations cannot escape the tree
  root (same guarantee as `/documents` and create).
- `rmdir`/`unlink` act only within the resolved-and-validated subtree; recursive
  delete is bounded to it.
- No authentication today; this inherits that posture (a deployment constraint,
  unchanged).

## Reliability Impact

- **No undo** is the headline risk, mitigated by the impact preview, the
  refuse-if-referenced delete, and (later) the versioning store.
- **Partial-apply**: a move/delete touches many files; a mid-apply failure leaves a
  partially-applied change the server reports but cannot roll back. Ordering is
  chosen to fail safe (compute all rewrites first; do the rename and link writes;
  report any per-file failures).
- **Asset-analysis completeness**: classification reads page bodies (authoritative
  for `assets/` refs) cross-checked with sidecars; a reference present in a body
  but missing from a sidecar is still counted, so a shared asset is never wrongly
  relocated.
- **FFI return codes** are checked (unlike `Log`), so a failed `rename`/`rmdir`
  surfaces rather than silently leaving an inconsistent tree.

## Compatibility Impact

- Supersedes RFC-0026's rename/move/delete deferral and its external-utility
  reconciliation contract.
- New `/tree` endpoints (`?move`, `?delete`, and a preview); no change to existing
  routes. `MicroHttp.Log` refactors to import FFI from `MicroHttp.FileOps`
  (behaviour unchanged).
- No new MicroHs capability beyond `rmdir(2)`.
- Flat (non-tree) document mode is unaffected.

## Testing and Quality Gates

- `make check` and `make editor-check`.
- Server (hspec): the link engine is the priority -- `pageLinks`, `resolveTarget`,
  `inboundTo`, `relativeBetween`, `rewriteLinks` across same-dir/`../`/`./`/index
  cases, external-target and code-fence exclusion, byte-preservation of unrelated
  text; section vs page move path computation including a move+rename that must fix
  internal `../<oldname>/` links routing through the renamed segment; sidecar
  shared/exclusive asset classification; parent-listing maintenance (remove the
  source bullet/card, add
  the relocated entry to the destination, synthesise when absent); delete refusal
  when referenced; `FileOps` rename/unlink/rmdir return-code handling and meta-dir
  co-move/removal. Filesystem cases use a `build/` fixture tree (per existing specs).
- Client (vitest): preview parsing, the destination-picker selection, referrer-list
  rendering, the rewrite-impact summary.
- Layout/UX browser-verified via `preview_*` (AGENTS.md).

## Rollout Plan

1. **Phase 1 -- Link engine.** [DONE] The pure module + exhaustive tests. No FS
   mutation. (`MicroHttp.DocumentLinks`.)
2. **Phase 2 -- FileOps + section move.** [DONE] `MicroHttp.FileOps`
   (`rename`/`unlink`/`rmdir`, checked return codes; `MicroHttp.Log` now imports the
   rename/unlink wrappers from it). General whole-tree link rewrite
   (`planMoveRewrites`, not boundary-special-cased). Parent index.md listing
   relocation (`MicroHttp.DocumentListing`: remove the source card, add the
   repointed card to the destination, synthesise when absent). `MicroHttp.TreeMove`
   wires the IO: page enumeration, refusals (root / cycle / collision / unsafe
   path), `rename(2)`, and the writes. Endpoint `POST /tree/*path?move` with form
   fields `to`/`slug`/`confirm`; `confirm` absent returns the impact plan as a
   dry-run preview (the Open Question's option (b): one endpoint, body-driven), and
   `confirm=true` applies it.
3. **Phase 3 -- Page move.** [DONE] Same-folder rename and cross-folder move
   (`MicroHttp.TreeMove.movePage`). Page-aware link rewrite (`planPageMove`: the
   moved page rewritten against its new directory, its travelling `assets/` refs
   left bare, inbound links fixed via the subtree machinery). Asset shared/exclusive
   analysis (`classifyAssets`/`assetNamesIn` over the union of body refs and sidecar
   `local_path` entries across all source-folder peers; exclusive relocate, shared
   copy). Sidecar meta directory co-moved. Parent-listing bullet relocated (the
   listing helper generalised to cards and bullets). Endpoint dispatch chooses page
   vs section move by whether the path ends `.md`.
4. **Phase 4 -- Delete.** [DONE] `MicroHttp.TreeMove.deleteTarget` +
   `referrersMatching`. The target's parent listing entry is excluded from the
   inbound scan (so it is never a self-blocker); any other inbound link refuses the
   delete with the referrer list (`Refused`, nothing written). Otherwise the target
   is routed to RFC-0028's trash (page: `.md` + meta dir + exclusive assets; section:
   whole folder) with a provenance manifest, the listing entry removed, and a
   `delete` op logged. Endpoint `POST /tree/*path?delete`.
5. **Phase 5 -- Client UX.** [DONE] Per-node **Move** and **Delete** actions in the
   nav tree (`nav-tree.ts`), hover-revealed like the create "+". Move prompts for a
   destination folder and optional slug, previews the impact (the dry-run `?move`
   reporting the count of files whose links change), and applies on confirmation;
   Delete confirms, then surfaces the referrer list on a refused (referenced) delete
   or moves to trash with an Undo hint. **Move is also a drag-and-drop gesture**:
   dragging a node onto a section drops into it (onto a page drops into that page's
   folder; onto the root list moves to the top level), with the same preview-confirm;
   self/descendant/no-op drops are rejected. Drag-and-drop is the sole move gesture
   (the earlier Move button was removed at the owner's request). Wired to
   `?move`/`?delete` via editor-element
   callbacks that catch network errors and surface a clear message (so a failed or
   unreachable request never silently does nothing). When the operation targets the
   **currently-open** document, the editor navigates away instead of stranding on a
   vanished file: a delete goes to the parent folder's index, a move follows the page
   to its new location (and a descendant of a moved/deleted section is handled too).
   Browser-verified against a scratch tree.

### Rollout Plan Escape Hatch

- If implementation reaches behaviour this RFC or its design contracts do not
  cover, stop changing the affected scope before inventing a contract.
- Add the smallest missing decision to `## Open Questions`, or to the owning RFC if
  another RFC owns the contract.
- Include evidence, impact, options, and a recommended path.
- Continue the affected implementation only after explicit reviewer or user
  approval.

## Open Questions

- **Preview transport** (resolved, Phase 2): option (b) -- one endpoint,
  `POST /tree/<path>?move` with the body carrying a `confirm` flag. Without
  `confirm=true` the server computes the move and returns the impact plan as JSON
  without writing; with it, the move is applied. Chosen over a separate
  `?move-preview` GET for parity with the existing body-driven create endpoint and
  to keep one code path; a local, reversible decision.
- **Anchor/query suffixes on link targets** (`foo.md#section`): preserved verbatim
  on rewrite; confirm none need path-relative anchor fix-ups.
- **Destination asset-name collision** (resolved, Phase 3): when a cross-folder page
  move would place an asset where the destination `assets/` already holds that name,
  identical content is reused (idempotent) and **differing** content **refuses** the
  whole move, naming the asset, rather than clobbering or content-hash-renaming. A
  local, reversible decision (the corpus has no cross-dir asset refs, so collisions
  are rare); content-addressed dedup-rename can be added later if a real case
  appears.
- **Section move with external inbound links**: rewrite them (as designed) vs also
  offer refuse-if-referenced like delete -- the design rewrites; confirm that is
  wanted for move (it is the point) and only delete refuses.

## Implied Decision Records (to add on acceptance)

- **ADR-0060**: Move/delete are in-server and link-preserving (including relocating
  the moved item's entry between parent index.md listings); supersedes
  RFC-0026's external-utility reconciliation contract.
- **ADR-0061**: Filesystem mutation uses a shared `MicroHttp.FileOps` (libc
  `rename`/`unlink`/`rmdir`, checked return codes).
- **ADR-0062**: Cross-folder page moves classify assets shared/exclusive via body
  refs + sidecars; exclusive relocate, shared copy.
- **ADR-0063**: Delete refuses while inbound links exist (no dangling links, no
  undo); recovery awaits the versioning store.

## CONTEXT.md additions (on acceptance)

- **Move**: relocating a **page** or **section** to a new parent and/or slug,
  with the server rewriting relative links and reconciling assets/sidecar.
- **Exclusive asset / shared asset**: a **peer asset** referenced by only the one
  **page** (exclusive) or by sibling pages too (shared); the distinction drives
  relocate-vs-copy on a cross-folder page move.
