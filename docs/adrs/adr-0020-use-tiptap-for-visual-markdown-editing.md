---
id: ADR-0020
name: Use Tiptap for Visual Markdown Editing
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: []
---

# ADR-0020: Use Tiptap for Visual Markdown Editing

## Context

The hand-built `contenteditable` visual surface proved the htmx and
web-component integration path, but each Markdown feature adds DOM parsing,
editing, and serialisation complexity to the custom element. The next editor
phase also needs toolbar controls, raw Markdown editing, syntax highlighting,
and future table/image/attachment workflows. Tiptap is framework-agnostic and
can run behind the existing custom element boundary. Its Markdown extension is
currently beta, so it should be introduced behind an adapter rather than becoming
an unwrapped project-wide contract.

## Decision

Use Tiptap/ProseMirror for the visual editing surface inside
`<markdown-editor>`. Keep Markdown text as the htmx/server contract. Keep
remark/mdast as the reference parser and validation fixture while Tiptap
Markdown support settles. Use CodeMirror for the future raw Markdown editor.
Use Web Awesome, the successor home for Shoelace, for future web-component UI
controls. (This Web Awesome clause is superseded by ADR-0076: Basecoat chrome
replaced Web Awesome under RFC-0035.) Consider Lit for the editor shell once toolbar state, mode switching,
and nested controls make manual DOM management hard to follow.

## Consequences

The next implementation slice should replace the visual
`contenteditable` surface with a Tiptap adapter while preserving existing source
mode, split mode, autosave events, and form submission behaviour. Toolbar,
CodeMirror, Web Awesome, and Lit integration should remain separate slices so the
editing-engine migration can be verified independently.
