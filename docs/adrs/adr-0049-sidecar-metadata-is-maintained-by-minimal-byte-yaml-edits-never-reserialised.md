---
id: ADR-0049
name: Sidecar Metadata Is Maintained By Minimal-Byte YAML Edits, Never Reserialised
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0049: Sidecar Metadata Is Maintained By Minimal-Byte YAML Edits, Never Reserialised

## Context

A tree page (ADR-0045) carries sidecar metadata in its meta directory
`<dir>/meta/<base>.meta/`: `attachments.yaml` and `images.yaml` list the page's
attachments and inline images, alongside an untouched `meta.yaml`. These files
were produced by a legacy CMS export and carry fields we do not reproduce for
new uploads (`id`, the original CMS `path`) with quoting and key order we do not
control. An upload (ADR-0046) writes the asset file but did not record it in this
metadata, and an inline image's `short_title` should follow the body image's alt
text. Maintaining these files by parsing the whole list and reserialising it
would rewrite every untouched legacy entry in our emitter's style -- dropping or
reformatting `id`/`path`, key order, and quoting -- so a diff against the corpus
would light up entries we never meant to change. That is unacceptable for an
in-place write into the user's real files.

## Decision

never reserialise a sidecar file. Maintain it with two minimal-byte
edits that touch only the bytes we own. (1) On upload (server-side in
`treeUpload`, reusing `inlineImageExtension` to pick the target file), append one
new entry block to the end -- or, when the file is the empty `[]`, replace that
with the single block. A new attachment entry carries `name` (the original
filename, single-quoted), `local_path` (`assets/<stored-name>`, already
URL-safe so unencoded), `extension`, and `external: false`; `id` and `path` are
omitted. A new image entry carries `local_path`, `short_title` (the filename at
creation), and `description: ''`. The append is idempotent and deduplicated by
`local_path` against the target file. (2) On save, the editor -- which already
parses the body and owns Markdown understanding (ADR-0040) -- sends a
`[{local_path, short_title}]` payload alongside the document; the server
surgically replaces only the `short_title:` value line within each matched
`local_path` block in `images.yaml`, updating nothing else and writing nothing
when the value is unchanged. The "alt text else filename" rule stays editor-side.
The meta directory and a missing target file are created on demand; `meta.yaml`
and the sibling file are not. Attachments stay append-only -- `name` is never
synced from body link text.

## Consequences

new uploads are recorded and inline-image `short_title` tracks the
edited alt text, while every untouched byte of these legacy files -- legacy
entries, `description`, key order, quoting -- stays identical, so a corpus diff
shows only the entries we added or the single values we changed. The cost is two
purpose-built, format-fragile editors (append a known-shape block; replace a
known key's value within a located block) instead of a general YAML reader and
writer; this is deliberate, since we only ever emit our own entry shape and edit
values we authored. The classification (images vs attachments) reuses the
existing `inlineImageExtension` so it is not duplicated across languages
(ADR-0040). Reading these files for the metadata panel is sidecar-metadata access,
not Markdown rendering, so it does not cross the ADR-0040 boundary. Concurrent
edits are out of scope (single-user local tool). Builds on ADR-0045/0046; consistent
with ADR-0040 (Markdown understanding stays browser-owned) and ADR-0047
(frontmatter is the in-page metadata; this is the out-of-page sidecar).
