interface DelimitedMarkdown {
    value: string;
    rest: string;
}

interface LinkMarkdown {
    label: string;
    url: string;
    rest: string;
}

/** Renders the supported Markdown subset to HTML. */
export function renderMarkdown(markdown: string): string {
    return markdown
        .split(/\n{2,}/)
        .map((block: string): string => renderBlock(block.trim()))
        .join("");
}

/** Renders one Markdown block to HTML. */
export function renderBlock(block: string): string {
    if (isUnorderedListBlock(block)) {
        return `<ul>${block
            .split("\n")
            .map((line: string): string => `<li>${renderInlineMarkdown(line.trim().slice(2))}</li>`)
            .join("")}</ul>`;
    }

    if (isOrderedListBlock(block)) {
        return `<ol>${block
            .split("\n")
            .map((line: string): string => `<li>${renderInlineMarkdown(orderedItemText(line))}</li>`)
            .join("")}</ol>`;
    }

    if (block.startsWith("### ")) {
        return `<h3>${renderInlineMarkdown(block.slice(4))}</h3>`;
    }

    if (block.startsWith("## ")) {
        return `<h2>${renderInlineMarkdown(block.slice(3))}</h2>`;
    }

    if (block.startsWith("# ")) {
        return `<h1>${renderInlineMarkdown(block.slice(2))}</h1>`;
    }

    return `<p>${renderInlineMarkdown(block)}</p>`;
}

/** Renders supported inline Markdown spans to HTML. */
export function renderInlineMarkdown(markdown: string): string {
    let html = "";
    let remaining = markdown;

    while (remaining.length > 0) {
        if (remaining.startsWith("**")) {
            const parsed = takeDelimited(remaining.slice(2), "**");

            if (parsed) {
                html += `<strong>${renderInlineMarkdown(parsed.value)}</strong>`;
                remaining = parsed.rest;
                continue;
            }
        }

        if (remaining.startsWith("*")) {
            const parsed = takeDelimited(remaining.slice(1), "*");

            if (parsed) {
                html += `<em>${renderInlineMarkdown(parsed.value)}</em>`;
                remaining = parsed.rest;
                continue;
            }
        }

        if (remaining.startsWith("`")) {
            const parsed = takeDelimited(remaining.slice(1), "`");

            if (parsed) {
                html += `<code>${escapeHtml(parsed.value)}</code>`;
                remaining = parsed.rest;
                continue;
            }
        }

        if (remaining.startsWith("[")) {
            const parsed = takeLink(remaining.slice(1));

            if (parsed) {
                html += `<a href="${escapeHtml(parsed.url)}">${renderInlineMarkdown(parsed.label)}</a>`;
                remaining = parsed.rest;
                continue;
            }
        }

        html += escapeHtml(remaining[0] ?? "");
        remaining = remaining.slice(1);
    }

    return html;
}

/** Takes a delimited Markdown span from the start of a string. */
function takeDelimited(markdown: string, delimiter: string): DelimitedMarkdown | null {
    const end = markdown.indexOf(delimiter);

    if (end < 0) {
        return null;
    }

    return {
        value: markdown.slice(0, end),
        rest: markdown.slice(end + delimiter.length),
    };
}

/** Takes a Markdown link from the start of a string. */
function takeLink(markdown: string): LinkMarkdown | null {
    const labelEnd = markdown.indexOf("](");

    if (labelEnd < 0) {
        return null;
    }

    const rest = markdown.slice(labelEnd + 2);
    const urlEnd = rest.indexOf(")");

    if (urlEnd < 0) {
        return null;
    }

    return {
        label: markdown.slice(0, labelEnd),
        url: rest.slice(0, urlEnd),
        rest: rest.slice(urlEnd + 1),
    };
}

/** Checks whether a block is an unordered list in the supported subset. */
function isUnorderedListBlock(block: string): boolean {
    return block.split("\n").every((line: string): boolean => /^[-*+] .+/.test(line.trim()));
}

/** Checks whether a block is an ordered list in the supported subset. */
function isOrderedListBlock(block: string): boolean {
    return block.split("\n").every((line: string): boolean => /^\d+\. .+/.test(line.trim()));
}

/** Removes the ordered-list marker from a line. */
function orderedItemText(line: string): string {
    return line.trim().replace(/^\d+\. /, "");
}

/** Escapes text for HTML text or attribute contexts. */
function escapeHtml(value: string): string {
    return value
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;")
        .replaceAll("'", "&#39;");
}
