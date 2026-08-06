/** Quotes Markdown lines as a blockquote while preserving indented code content. */
export function quoteMarkdownLines(markdown: string): string {
    return markdown
        .split("\n")
        .map((line: string): string => quoteMarkdownLine(line))
        .join("\n");
}

/** Quotes one Markdown line, leaving indented code content unspaced. */
function quoteMarkdownLine(line: string): string {
    if (!line) {
        return ">";
    }

    if (line.startsWith("    ")) {
        return `>${line}`;
    }

    return `> ${line}`;
}
