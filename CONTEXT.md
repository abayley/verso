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
_Avoid_: preview (that is the editor's split pane), view mode.

**Edit view**:
The editable presentation of a **page** (`?edit`): the full editor with the
editing controls and autosave.
_Avoid_: editor mode.

**Raw Markdown**:
A **page**'s verbatim Markdown bytes, including **frontmatter** (`?raw`), for
tooling and diffs.
_Avoid_: source (that is the editor's Markdown view).

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

## Flagged ambiguities

- **Metadata**: unqualified, it is ambiguous. Use **frontmatter** for the
  in-page block, **sidecar metadata** for the **meta directory** files, and
  **metadata panel** for the editor chrome.
- **Name vs short_title vs alt text**: an **attachment** entry's `name` is its
  canonical filename; an **inline image** entry's `short_title` mirrors the
  body image's **alt text** (falling back to the filename). They are not
  interchangeable, and `name` is not synced from body link text.

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
