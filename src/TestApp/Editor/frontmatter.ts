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

/** Reads the document title from the frontmatter `name:` field (unquoted), or null when absent. */
export function frontmatterName(frontmatter: string | null): string | null {
    if (frontmatter === null) {
        return null;
    }

    for (const line of frontmatter.split("\n")) {
        const match = /^name:[ \t]*(.*)$/.exec(line);

        if (match) {
            return unquoteYamlScalar((match[1] ?? "").trim());
        }
    }

    return null;
}

/**
 * Sets the frontmatter `name:` field to the given title, touching only that line (ADR-049: minimal-byte YAML
 * edits, the rest of the block preserved verbatim). Replaces the existing `name:` value, inserts a `name:`
 * line after the opening `---` when absent, or creates a whole frontmatter block when there is none.
 */
export function setFrontmatterName(frontmatter: string | null, name: string): string {
    const line = `name: ${formatYamlScalar(name)}`;

    if (frontmatter === null) {
        return `---\n${line}\n---`;
    }

    const lines = frontmatter.split("\n");
    const index = lines.findIndex((entry: string): boolean => /^name:[ \t]*/.test(entry));

    if (index >= 0) {
        lines[index] = line;
    } else {
        lines.splice(1, 0, line);
    }

    return lines.join("\n");
}

/** Strips matching single/double quotes from a YAML scalar and unescapes them. */
function unquoteYamlScalar(value: string): string {
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        return value.slice(1, -1).replace(/\\(["\\])/g, "$1");
    }

    if (value.length >= 2 && value.startsWith("'") && value.endsWith("'")) {
        return value.slice(1, -1).replace(/''/g, "'");
    }

    return value;
}

/** Formats a title as a YAML scalar: plain when safe, otherwise a double-quoted, escaped string. */
function formatYamlScalar(name: string): string {
    if (/^[A-Za-z0-9][A-Za-z0-9 _\-/.()]*$/.test(name) && !name.endsWith(" ")) {
        return name;
    }

    return `"${name.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}
