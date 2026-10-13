---
id: ADR-0071
name: Mermaid as a Lazily-Loaded Code Block, Not a Bundled Node Type
status: Accepted
owners:
    - Alistair Bayley
supersedes: []
superseded_by: null
related_rfcs: [RFC-0033]
---

# ADR-0071: Mermaid as a Lazily-Loaded Code Block, Not a Bundled Node Type

> Status: Accepted (RFC-0033).

## Context

RFC-0033 adds syntax highlighting to fenced code blocks and renders a
`mermaid` fence as a diagram. Rendering is entirely client-side in the Tiptap
visual editor (the server serves raw Markdown into the editor shell; there is no
server-side Markdown-to-HTML step). The editor ships as one minified IIFE bundle
with no code-splitting. Two design choices in this area are non-obvious and costly
to change later, so they are recorded here.

## Decision

- **Mermaid is delivered as a separately built, lazily-loaded bundle**
  (`packages/verso/static/editor/mermaid.js`, its own build entrypoint), fetched on demand only
  when an open page actually contains a `mermaid` fence, rather than inlined into
  the main editor bundle. Mermaid is very large; inlining would make every editor
  and read page -- the vast majority with no diagrams -- pay its download and parse
  cost. The bundle is served from the app's own origin (no CDN), initialised with
  `securityLevel: "strict"` (its bundled DOMPurify), and its version is pinned
  exactly so upgrades are deliberate, reviewed changes.
- **A Mermaid diagram is modelled as an ordinary code block** (the standard
  code-block node with `language: "mermaid"`) carrying a NodeView that renders the
  diagram, **not** as a distinct Tiptap node type with its own serialiser. The
  NodeView keeps the code-block DOM shape (a `<pre>` root with a
  `<code class="language-mermaid">` holding the source, hidden while the diagram
  shows), so the existing `codeBlockFromElement` serialiser -- which keys on
  `tagName === "PRE"` and reads `code.textContent` -- round-trips it to a
  ```` ```mermaid ```` fence with no new serialisation code. Syntax highlighting
  (lowlight) is likewise round-trip-safe because that serialiser reads `textContent`
  (flattening highlight token spans) and the `language-` class.

Alternatives rejected: inlining Mermaid into the main bundle (simpler build, but a
large cost on every page); a dedicated `mermaid` node type with its own
parse/serialise handlers (a second serialisation path to keep consistent with
`codeBlockFromElement`, for no gain, and a portability risk if it diverged).

## Consequences

pages without diagrams are unaffected by Mermaid's weight; a Mermaid
diagram is honestly "just a fenced code block with a renderer" and stays plain,
portable Markdown with no stored image. The cost is a second build entrypoint and a
runtime on-demand loader, and a NodeView that must keep its source `<code>` in the
DOM (hidden) for both ProseMirror and the serialiser to read. Vocabulary (Mermaid
diagram) is recorded in GLOSSARY.md.
