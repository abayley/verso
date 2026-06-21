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

**Metadata panel**:
The editor chrome panel that surfaces a page's **sidecar metadata** -- for now,
the list of **attachments** (including unlinked ones). One of three planned
panels (the others being a navigation tree and a table of contents).
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

## Flagged ambiguities

- **Metadata**: unqualified, it is ambiguous. Use **frontmatter** for the
  in-page block, **sidecar metadata** for the **meta directory** files, and
  **metadata panel** for the editor chrome.
- **Name vs short_title vs alt text**: an **attachment** entry's `name` is its
  canonical filename; an **inline image** entry's `short_title` mirrors the
  body image's **alt text** (falling back to the filename). They are not
  interchangeable, and `name` is not synced from body link text.
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
