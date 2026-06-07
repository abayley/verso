import type { EditorBlock, EditorDocument, InlineNode } from "./editor-model.js";

interface DelimitedMarkdown {
    value: string;
    rest: string;
}

interface LinkMarkdown {
    label: string;
    url: string;
    rest: string;
}

/** Parses Markdown in the supported subset into an editor document. */
export function parseMarkdown(markdown: string): EditorDocument {
    return {
        blocks: markdown
            .split(/\n{2,}/)
            .map((block: string): string => block.trim())
            .filter((block: string): boolean => block.length > 0)
            .map((block: string): EditorBlock => parseBlock(block)),
    };
}

/** Parses one Markdown block into an editor block. */
function parseBlock(block: string): EditorBlock {
    if (isUnorderedListBlock(block)) {
        return {
            items: block.split("\n").map((line: string): InlineNode[] => parseInlineMarkdown(line.trim().slice(2))),
            ordered: false,
            type: "list",
        };
    }

    if (isOrderedListBlock(block)) {
        return {
            items: block.split("\n").map((line: string): InlineNode[] => parseInlineMarkdown(orderedItemText(line))),
            ordered: true,
            type: "list",
        };
    }

    if (block.startsWith("### ")) {
        return {
            children: parseInlineMarkdown(block.slice(4)),
            level: 3,
            type: "heading",
        };
    }

    if (block.startsWith("## ")) {
        return {
            children: parseInlineMarkdown(block.slice(3)),
            level: 2,
            type: "heading",
        };
    }

    if (block.startsWith("# ")) {
        return {
            children: parseInlineMarkdown(block.slice(2)),
            level: 1,
            type: "heading",
        };
    }

    return {
        children: parseInlineMarkdown(block),
        type: "paragraph",
    };
}

/** Parses supported inline Markdown spans into inline nodes. */
function parseInlineMarkdown(markdown: string): InlineNode[] {
    const nodes: InlineNode[] = [];
    let text = "";
    let remaining = markdown;

    while (remaining.length > 0) {
        if (remaining.startsWith("**")) {
            const parsed = takeDelimited(remaining.slice(2), "**");

            if (parsed) {
                appendText(nodes, text);
                text = "";
                nodes.push({
                    children: parseInlineMarkdown(parsed.value),
                    type: "strong",
                });
                remaining = parsed.rest;
                continue;
            }
        }

        if (remaining.startsWith("*")) {
            const parsed = takeDelimited(remaining.slice(1), "*");

            if (parsed) {
                appendText(nodes, text);
                text = "";
                nodes.push({
                    children: parseInlineMarkdown(parsed.value),
                    type: "emphasis",
                });
                remaining = parsed.rest;
                continue;
            }
        }

        if (remaining.startsWith("`")) {
            const parsed = takeDelimited(remaining.slice(1), "`");

            if (parsed) {
                appendText(nodes, text);
                text = "";
                nodes.push({
                    text: parsed.value,
                    type: "code",
                });
                remaining = parsed.rest;
                continue;
            }
        }

        if (remaining.startsWith("[")) {
            const parsed = takeLink(remaining.slice(1));

            if (parsed) {
                appendText(nodes, text);
                text = "";
                nodes.push({
                    children: parseInlineMarkdown(parsed.label),
                    type: "link",
                    url: parsed.url,
                });
                remaining = parsed.rest;
                continue;
            }
        }

        text += remaining[0] ?? "";
        remaining = remaining.slice(1);
    }

    appendText(nodes, text);
    return nodes;
}

/** Appends a text node when the text is non-empty. */
function appendText(nodes: InlineNode[], text: string): void {
    if (text.length === 0) {
        return;
    }

    nodes.push({
        text,
        type: "text",
    });
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
