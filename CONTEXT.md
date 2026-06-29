# MicroHttp Document Tree

The language of the editor's **document-tree mode**: serving and editing an
existing MkDocs-style documentation tree on the filesystem in place (ADR-045).
This glossary covers the tree's layout and its sidecar metadata; it is not a
spec.

## Language

**Document tree**:
A filesystem tree of nested section folders and Markdown **pages**, served and
edited in place under `/documents/`. Selected by the `document_tree_root`
config key.
_Avoid_: corpus (informal; means the same thing), repo.

**Page**:
A single Markdown document in the tree, identified by its tree-relative path
including `.md`. The unit a reader views and an author edits.
_Avoid_: file (too generic), article.

**Section**:
A folder of the **document tree**, holding nested **sections** and **pages**.
Its title and landing page are its `index.md` (a **page**); selecting a section
opens that `index.md`. By convention every section has an `index.md`; one lacking
it shows a humanised label and is expand-only (no landing page). A section's
`index.md` is folded into the section, not shown as a separate child.
_Avoid_: directory (filesystem term), category, subsection.

**Index.md listing**:
A **section**'s listing, in its `index.md`, of its direct members: **subsections**
as `grid cards` (`- :icon: __[Title](./child/index.md)__` with a description span)
and **pages** as plain bullets (`- [Title](./page.md)`). The section landing page's
table of its children, kept in step as members are created, **moved**, or deleted.
_Avoid_: contents listing, member listing, nav.

**Move**:
Relocating a **page** or **section** to a new parent **section** and/or a new
slug (RFC-0027). The server keeps the tree consistent: relative links across the
tree are rewritten, the item's **sidecar metadata** travels with it, **peer
assets** are reconciled, and the parent sections' listings are updated. A move that
keeps the parent (just a slug change) is the "rename" case; editing the **title**
(frontmatter `name`) is not a move and changes no path (see **Title vs slug**).
_Avoid_: rename (a UX label for the same-parent slug change, not a separate
operation).

**Operation log**:
An append-only log, held outside the **document tree**, of the **navigation
tree**'s structural operations -- **moves** and deletes -- as _logical_ records
(the intent: kind and paths), not file-level diffs (RFC-0028). It is replayed on a
refreshed corpus to re-apply the reorganisation; undo appends each operation's
inverse (a move's reverse move, a delete's restore). Distinct from the
**revision history** (git content history); the two coexist (RFC-0032).
_Avoid_: move log (it records deletes too), revision history (that is the git
history), audit trail.

**Trash**:
The area outside the **document tree** (but on the same filesystem) a deleted
**page** or **section** is moved to -- rather than destroyed -- with a provenance
record of its original tree path, so it can be restored (RFC-0028). Browsed and
recovered through a Trash view in the **navigation tree**; restore is refused if
the original location is now occupied.
_Avoid_: recycle bin, archive, bin.

**Draft**:
An unpublished, staged edit of a **page** (RFC-0032). Autosave in the **edit
view** writes the draft -- held under a draft root _outside_ the **document
tree** -- rather than the live page, so an in-progress edit never changes what a
reader sees and survives navigating away. Editing a page with a draft resumes it;
the **read view** marks the page "(unpublished draft)".
_Avoid_: working copy, scratch, autosave (autosave is the mechanism that writes a draft).

**Publish**:
The author action (RFC-0032) that promotes a **draft** into the **document
tree** as a new **revision** and clears the draft. The **edit view**'s primary
control is "Publish"; it commits and returns to the **read view** -- the way to
leave edit mode.
_Avoid_: save (save is the autosave-to-draft step), commit (the git mechanism), submit.

**Revision**:
A git commit that changed one or more **pages** (RFC-0032): a **publish**, a
structural operation (**move**/delete/restore), or a **rollback**. Identified by
its commit hash, timestamp, **author identity**, and message.
_Avoid_: version (overloaded), commit (the git term), snapshot.

**Revision history**:
The ordered **revisions** affecting a **page**, read from git and followed across
**moves** (RFC-0032). Shown in a per-page history view reachable from the
**metadata panel**, where two revisions can be diffed and a page rolled back to an
earlier one. Distinct from the **operation log**.
_Avoid_: history (ambiguous -- it is the git revision history), changelog, audit log.

**Author identity**:
The faked author name attached to a **revision** and shown in the **revision
history** (RFC-0032). Derived from a configurable request header (default
`X-Remote-User`), falling back to a configured default name; there is no
authentication. The single seam real auth would later replace.
_Avoid_: user, account, login (there is no authentication).

**Read view**:
The default rendered, read-only presentation of a **page** (a plain `GET` of its
URL). It is the **edit view**'s shell with editing switched off (RFC-0020,
ADR-050).
_Avoid_: preview (no such pane exists -- see **Split view**), view mode.

**Edit view**:
The editable presentation of a **page** (`?edit`): the full editor with the
editing controls and autosave. Shown in one of three **view modes**.
_Avoid_: editor mode.

**Visual view**:
The WYSIWYG **view mode**: the Tiptap editing surface. The default, and the
surface the **read view** also uses (with editing off). The only surface that
renders the page's formatting.
_Avoid_: rich text, preview.

**Markdown view**:
The raw-text **view mode**: a CodeMirror editor over the page's **raw Markdown**
body. Plain text, no rendering.
_Avoid_: source view, code view.

**Split view**:
The **view mode** showing the **Markdown view** and **Visual view** side by
side, kept in sync. The right-hand pane is the live **Visual view**, not a
rendered preview.
_Avoid_: preview pane, side-by-side.

**Raw Markdown**:
A **page**'s verbatim Markdown bytes, including **frontmatter** (`?raw`), for
tooling and diffs.
_Avoid_: source (that is the **Markdown view**).

**Peer assets**:
A page's sibling `assets/` folder, holding the images and attachments that page
references page-relative (`assets/x.png`). Each page directory has its own.
_Avoid_: uploads, media.

**Asset**:
A file in a page's **peer assets** folder. Classified by extension into an
**inline image** (png/jpg/jpeg/gif/webp) or an **attachment** (everything else:
svg, pdf, and the document types).
_Avoid_: upload, file.

**Inline image**:
An asset embedded in the page body as `![alt](assets/x.png)` and listed in the
page's `images.yaml`.
_Avoid_: picture.

**Attachment**:
A non-image asset, referenced as a download link `[name](assets/x.pdf)` (or not
referenced at all) and listed in the page's `attachments.yaml`. An attachment
may be **unlinked** -- present and recorded but not referenced from the body.
_Avoid_: download, file.

**Exclusive asset / shared asset**:
Within a folder's shared **peer assets**, an **asset** referenced by only one
**page** (exclusive to it) or by more than one (shared). Ownership is a folder-wide
question -- the `assets/` folder is shared by every page at that level -- so it is
settled by scanning all peer pages' bodies and **sidecar metadata**
(`attachments.yaml`/`images.yaml`), not one page's. The distinction drives
relocate-vs-copy when a page **moves** between folders.
_Avoid_: owned asset, orphan asset.

**Sidecar metadata**:
Per-page metadata held outside the page body, in the page's **meta directory**,
distinct from **frontmatter** (which is in-page). Three YAML files:
`attachments.yaml`, `images.yaml`, `meta.yaml`.
_Avoid_: metadata (ambiguous on its own), sidecar.

**Meta directory**:
A page's sidecar-metadata folder: for a page `<dir>/<base>.md`, the directory
`<dir>/meta/<base>.meta/`. An `index.md` page uses `<dir>/meta/index.meta/`.
_Avoid_: meta folder, `.meta`.

**Frontmatter**:
The page's own leading `---...---` YAML block, in the page body. Preserved and
hidden from editing (ADR-047). Distinct from **sidecar metadata**.
_Avoid_: header, metadata.

**Badge**:
An inline lozenge written as an inline code span with a `{.badge.<colour>}`
attribute list, e.g. `` `TODO`{.badge.yellow} ``; rendered as a coloured pill
(RFC-0021). The text is literal (a code span) and carries no other inline
formatting.
_Avoid_: label, tag, pill (pill is the rendered shape, not the construct).

**Navigation tree**:
The editor chrome panel, on the left of the **read view** and **edit view**, that
shows the **document tree**'s **sections** and **pages** for browsing and managing
them. A section row's disclosure control expands/collapses its children; the row
label opens the section (its `index.md`). One of the three panels (with the
**metadata panel** and the table of contents).
_Avoid_: sidebar (ambiguous; there are several), file tree, file explorer.

**Metadata panel**:
The editor chrome panel that surfaces a page's **sidecar metadata** -- for now,
the list of **attachments** (including unlinked ones). One of three panels (with
the **navigation tree** and a table of contents).
_Avoid_: sidebar (ambiguous; there are several), attachments panel.

**Round-trip stability**:
The editor's saved-page contract: reopening a saved **page** shows the author
what they last saw. Saving then loading is stable -- the **edit view** renders
saved **raw Markdown** identically to the state it was saved from. Measured
through the real editing pipeline (load -> edit -> serialise -> save -> load),
not against any external grammar. The property a `?raw` diff or a downstream
renderer may still differ on; this contract is about the editor with itself.
_Avoid_: round-trippable subset (conflates the contract with one past mechanism),
representable, valid Markdown.

**Client-error report**:
One captured client-side editor failure, sent from the editor's error boundary
to the server for operational visibility. A bounded, privacy-safe record (no
**page** body content, no user identity) -- not the user-facing banner, which is
the in-browser surfacing of the same failure (RFC-0022).
_Avoid_: crash report, exception, log entry.

**Client-error log**:
The dedicated logfmt file the server appends **client-error reports** to,
separate from the access log. The operator's after-the-fact view of editor
failures ("Sentry-like" meaning the outcome -- queryable error visibility -- not
the Sentry protocol). Selected by the `client_error_log` config key (RFC-0023).
_Avoid_: telemetry, access log (a different file, HTTP-request lifecycle).

**Link index**:
The server's in-memory resolved `.md`->`.md` link graph of the **document tree**
(each **page**'s outbound `.md` link targets and the inverted `tree path ->
referring pages` map), consulted by **move** and delete to find referrers and
rewrite sets without scanning every page. Kept correct by a per-operation
freshness check -- a `(path, mtime, size)` fingerprint of every `.md`; an
operation re-stats the tree and rebuilds the index if it changed out-of-band --
so it never serves a stale answer (preserving the **navigation tree**'s
always-correct contract, ADR-059). Built lazily on first use and re-synced in
lockstep after each in-server mutation (RFC-0029, ADR-066/067).
_Avoid_: cache (it never serves a stale answer), search index (titles/full text;
a separate future system), sitemap.

## Flagged ambiguities

- **Metadata**: unqualified, it is ambiguous. Use **frontmatter** for the
  in-page block, **sidecar metadata** for the **meta directory** files, and
  **metadata panel** for the editor chrome.
- **Name vs short_title vs alt text**: an **attachment** entry's `name` is its
  canonical filename; an **inline image** entry's `short_title` mirrors the
  body image's **alt text** (falling back to the filename). They are not
  interchangeable, and `name` is not synced from body link text.
- **Title vs slug**: a **page**'s display title is its **frontmatter** `name`;
  its slug is the filename/path segment (and so its URL). They are deliberately
  independent and not synced -- editing the title (ADR-057) never renames the
  file. A new page derives an initial slug from its title, after which they
  diverge freely. Changing the slug is a **Move** (RFC-0027), not a title edit. The
  **navigation tree** and breadcrumbs show the title; the filesystem and URLs use
  the slug.
- **Preview**: there is no rendered-preview pane anywhere in the editor. The
  **read view** and **Visual view** render via Tiptap; the **Split view**'s
  right pane is the live **Visual view**. "Preview" denotes nothing -- do not
  reach for it (RFC-0022 removed the last vestige, an always-null preview slot).

## Example dialogue

> **Dev**: When someone uploads a PDF to the anzco overview page, where does it
> go?
>
> **Author**: Into that page's peer assets -- `tenants/anzco/assets/`. And it
> gets recorded as an attachment in the page's meta directory,
> `tenants/anzco/meta/overview.meta/attachments.yaml`.
>
> **Dev**: Even if the body never links it?
>
> **Author**: Yes -- that's an unlinked attachment. The metadata panel still
> shows it, so the author can find it and drag it into the page.
>
> **Dev**: And if they drop in a screenshot instead?
>
> **Author**: That's an inline image, so it goes in `images.yaml`, and its
> short_title tracks the alt text on the body image.
