// Splits a document's leading YAML frontmatter from its Markdown body, and re-joins them. The editor
// preserves frontmatter without exposing it for editing (RFC-/ADR-tracked): it is stripped on load so the
// editors only ever see the body, and re-attached verbatim when the document is persisted. The body is the
// editor's own concern and is re-serialised canonically; the frontmatter block is carried unchanged.

/** A document separated into its optional frontmatter block and its Markdown body. */
export interface SplitDocument {
    /** The verbatim `---`-delimited frontmatter block, or null when the document has none. */
    frontmatter: string | null;
    /** The Markdown body after the frontmatter (or the whole document when there is none). */
    body: string;
}

// Frontmatter is a `---` line at the very start, YAML, then a closing `---` line (the first one wins, as
// gray-matter and remark-frontmatter treat it). A leading `---` with no closing delimiter is a thematic
// break, not frontmatter.
const FRONTMATTER_PATTERN = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/;

/** Separates a document's leading frontmatter from its body, or reports no frontmatter. */
export function splitFrontmatter(markdown: string): SplitDocument {
    const match = FRONTMATTER_PATTERN.exec(markdown);

    if (!match) {
        return { frontmatter: null, body: markdown };
    }

    const inner = match[1] ?? "";
    const body = markdown.slice(match[0].length).replace(/^\s*\n/, "");

    return { frontmatter: `---\n${inner}\n---`, body };
}

/** Re-attaches a preserved frontmatter block to a body, separated by a blank line. */
export function joinFrontmatter(frontmatter: string | null, body: string): string {
    return frontmatter === null ? body : `${frontmatter}\n\n${body}`;
}
