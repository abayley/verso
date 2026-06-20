import type { ListItem, PhrasingContent, RootContent } from "mdast";
import {
    type ContentExtension,
    type FromElementContext,
    type ParseContext,
    type RenderContext,
    registerExtension,
    type ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock, InlineNode, ListItemBlock } from "./editor-model.js";

// Parse: mdast -> editor block.

/** Converts a built-in mdast block node into an editor block, or declines an unrecognised node. */
function blockFromMdast(node: RootContent, ctx: ParseContext): EditorBlock | null {
    if (node.type === "heading") {
        if (node.depth !== 1 && node.depth !== 2 && node.depth !== 3) {
            throw ctx.unsupportedNode(`heading:${node.depth}`);
        }

        return {
            children: ctx.inlinesFromMdast(node.children),
            level: node.depth,
            type: "heading",
        };
    }

    if (node.type === "paragraph") {
        return {
            children: ctx.inlinesFromMdast(node.children),
            type: "paragraph",
        };
    }

    if (node.type === "list") {
        return {
            items: node.children.map((item: ListItem): ListItemBlock => listItemFromMdast(item, ctx)),
            ordered: node.ordered === true,
            type: "list",
        };
    }

    if (node.type === "thematicBreak") {
        return {
            type: "horizontalRule",
        };
    }

    if (node.type === "code") {
        return {
            language: node.lang ?? null,
            text: node.value,
            type: "codeBlock",
        };
    }

    if (node.type === "blockquote") {
        return {
            blocks: ctx.blocksFromMdast(node.children),
            type: "blockquote",
        };
    }

    return null;
}

/** Converts a built-in mdast list item into editor item blocks. */
function listItemFromMdast(item: ListItem, ctx: ParseContext): ListItemBlock {
    // A bare marker (e.g. `1.` on its own line) is a valid, empty CommonMark list item. The visual
    // editor (marked) accepts it, and the visual->Markdown round-trip can produce one, so the subset
    // must too: model it as a single empty paragraph rather than rejecting the whole document.
    if (item.children.length === 0) {
        return {
            blocks: [{ children: [], type: "paragraph" }],
        };
    }

    return {
        blocks: ctx.blocksFromMdast(item.children),
    };
}

// Parse: mdast -> editor inline.

/** Converts a built-in mdast phrasing node into an editor inline node, or declines an unrecognised node. */
function inlineFromMdast(node: PhrasingContent, ctx: ParseContext): InlineNode | null {
    if (node.type === "text") {
        return {
            text: node.value,
            type: "text",
        };
    }

    if (node.type === "strong") {
        return {
            children: ctx.inlinesFromMdast(node.children),
            type: "strong",
        };
    }

    if (node.type === "emphasis") {
        return {
            children: ctx.inlinesFromMdast(node.children),
            type: "emphasis",
        };
    }

    if (node.type === "delete") {
        return {
            children: ctx.inlinesFromMdast(node.children),
            type: "strikethrough",
        };
    }

    if (node.type === "inlineCode") {
        return {
            text: node.value,
            type: "code",
        };
    }

    if (node.type === "link") {
        return {
            children: ctx.inlinesFromMdast(node.children),
            type: "link",
            url: node.url,
        };
    }

    if (node.type === "break") {
        return {
            type: "break",
        };
    }

    return null;
}

// Render: editor block -> HTML.

/** Renders a built-in editor block to HTML, or declines an unrecognised block. */
function renderBlock(block: EditorBlock, ctx: RenderContext): string | null {
    if (block.type === "heading") {
        return `<h${block.level}>${ctx.renderInlines(block.children)}</h${block.level}>`;
    }

    if (block.type === "list") {
        const tag = block.ordered ? "ol" : "ul";

        return `<${tag}>${block.items.map((item: ListItemBlock): string => renderListItem(item, ctx)).join("")}</${tag}>`;
    }

    if (block.type === "horizontalRule") {
        return "<hr>";
    }

    if (block.type === "codeBlock") {
        const languageClass = block.language ? ` class="language-${ctx.escapeHtml(block.language)}"` : "";

        return `<pre><code${languageClass}>${ctx.escapeHtml(block.text)}</code></pre>`;
    }

    if (block.type === "blockquote") {
        return `<blockquote>${ctx.renderBlocks(block.blocks)}</blockquote>`;
    }

    if (block.type === "paragraph") {
        return `<p>${ctx.renderInlines(block.children)}</p>`;
    }

    return null;
}

/** Renders one list item, keeping tight single-paragraph items compact. */
function renderListItem(item: ListItemBlock, ctx: RenderContext): string {
    if (item.blocks.length === 1 && item.blocks[0]?.type === "paragraph") {
        return `<li>${ctx.renderInlines(item.blocks[0].children)}</li>`;
    }

    return `<li>${ctx.renderBlocks(item.blocks)}</li>`;
}

// Render: editor inline -> HTML.

/** Renders a built-in editor inline node to HTML, or declines an unrecognised node. */
function renderInline(node: InlineNode, ctx: RenderContext): string | null {
    if (node.type === "strong") {
        return `<strong>${ctx.renderInlines(node.children)}</strong>`;
    }

    if (node.type === "emphasis") {
        return `<em>${ctx.renderInlines(node.children)}</em>`;
    }

    if (node.type === "strikethrough") {
        return `<del>${ctx.renderInlines(node.children)}</del>`;
    }

    if (node.type === "code") {
        return `<code>${ctx.escapeHtml(node.text)}</code>`;
    }

    if (node.type === "link") {
        return `<a href="${ctx.escapeHtml(node.url)}">${ctx.renderInlines(node.children)}</a>`;
    }

    if (node.type === "break") {
        return "<br>";
    }

    if (node.type === "text") {
        return ctx.escapeHtml(node.text);
    }

    return null;
}

// Serialise-in: DOM element -> editor block. The base extension is the final fallback, so any
// unrecognised element becomes a paragraph (matching the previous closed dispatcher's default).

/** Converts a DOM block element to an editor block, treating any unrecognised element as a paragraph. */
function blockFromElement(block: Element, ctx: FromElementContext): EditorBlock {
    if (block.tagName === "HR") {
        return {
            type: "horizontalRule",
        };
    }

    if (block.tagName === "PRE") {
        return codeBlockFromElement(block);
    }

    if (block.tagName === "BLOCKQUOTE") {
        return {
            blocks: ctx.documentFromElements(block.children).blocks,
            type: "blockquote",
        };
    }

    if (block.tagName === "H1") {
        return {
            children: ctx.inlinesFromElement(block),
            level: 1,
            type: "heading",
        };
    }

    if (block.tagName === "H2") {
        return {
            children: ctx.inlinesFromElement(block),
            level: 2,
            type: "heading",
        };
    }

    if (block.tagName === "H3") {
        return {
            children: ctx.inlinesFromElement(block),
            level: 3,
            type: "heading",
        };
    }

    if (block.tagName === "UL") {
        return {
            items: Array.from(block.children).map((item: Element): ListItemBlock => listItemFromElement(item, ctx)),
            ordered: false,
            type: "list",
        };
    }

    if (block.tagName === "OL") {
        return {
            items: Array.from(block.children).map((item: Element): ListItemBlock => listItemFromElement(item, ctx)),
            ordered: true,
            type: "list",
        };
    }

    return {
        children: ctx.inlinesFromElement(block),
        type: "paragraph",
    };
}

/** Converts a list item element to editor item blocks. */
function listItemFromElement(item: Element, ctx: FromElementContext): ListItemBlock {
    if (hasBlockChildren(item)) {
        return {
            blocks: ctx.documentFromElements(item.children).blocks,
        };
    }

    return {
        blocks: [
            {
                children: ctx.inlinesFromElement(item),
                type: "paragraph",
            },
        ],
    };
}

/** Checks whether an element contains child blocks rather than only phrasing content. */
function hasBlockChildren(element: Element): boolean {
    return Array.from(element.children).some((child: Element): boolean => isBlockElement(child));
}

/** Checks whether an element is a supported Markdown block element. */
function isBlockElement(element: Element): boolean {
    return ["BLOCKQUOTE", "H1", "H2", "H3", "HR", "OL", "P", "PRE", "UL"].includes(element.tagName);
}

/** Converts one inline DOM node to built-in editor inline nodes (the base extension's inline serialise-in). */
function inlineFromElement(node: ChildNode, ctx: FromElementContext): InlineNode[] {
    if (node.nodeType === Node.TEXT_NODE) {
        return textNode(node.textContent ?? "");
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
        return [];
    }

    const element = node as Element;

    if (element.tagName === "BR") {
        // ProseMirror inserts a trailing <br> into empty textblocks for cursor visibility; it is an
        // editor artifact, not content (a real hard break carries no such class).
        if (element.classList.contains("ProseMirror-trailingBreak")) {
            return [];
        }

        return [
            {
                type: "break",
            },
        ];
    }

    if (element.tagName === "STRONG" || element.tagName === "B") {
        return [
            {
                children: ctx.inlinesFromElement(element),
                type: "strong",
            },
        ];
    }

    if (element.tagName === "EM" || element.tagName === "I") {
        return [
            {
                children: ctx.inlinesFromElement(element),
                type: "emphasis",
            },
        ];
    }

    if (element.tagName === "DEL" || element.tagName === "S" || element.tagName === "STRIKE") {
        return [
            {
                children: ctx.inlinesFromElement(element),
                type: "strikethrough",
            },
        ];
    }

    if (element.tagName === "CODE") {
        return [
            {
                text: (element as HTMLElement).innerText,
                type: "code",
            },
        ];
    }

    if (element.tagName === "A") {
        return [
            {
                children: ctx.inlinesFromElement(element),
                type: "link",
                url: element.getAttribute("href") ?? "",
            },
        ];
    }

    return ctx.inlinesFromElement(element);
}

/** Converts a preformatted DOM block to an editor code block. */
function codeBlockFromElement(block: Element): EditorBlock {
    const code = block.querySelector("code");

    return {
        language: code ? codeLanguage(code) : null,
        text: code?.textContent ?? block.textContent ?? "",
        type: "codeBlock",
    };
}

// Serialise-out: editor block -> Markdown. The base extension is the final fallback, so any
// unrecognised block serialises as a paragraph (matching the previous closed dispatcher's default).

/** Serialises a built-in editor block to Markdown, treating any unrecognised block as a paragraph. */
function blockToMarkdown(block: EditorBlock, ctx: ToMarkdownContext): string {
    if (block.type === "horizontalRule") {
        return "---";
    }

    if (block.type === "codeBlock") {
        return [`\`\`\`${block.language ?? ""}`, block.text, "```"].join("\n");
    }

    if (block.type === "blockquote") {
        return ctx
            .documentToMarkdown({ blocks: block.blocks })
            .split("\n")
            .map((line: string): string => blockquoteLineToMarkdown(line))
            .join("\n");
    }

    if (block.type === "heading") {
        return `${"#".repeat(block.level)} ${ctx.inlinesToMarkdown(block.children).trim()}`;
    }

    if (block.type === "list") {
        return block.items.reduce((markdown: string, item: ListItemBlock, index: number): string => {
            const marker = block.ordered ? `${index + 1}.` : "-";
            const separator = index === 0 ? "" : listItemSeparator(block.items[index - 1]);

            return `${markdown}${separator}${listItemToMarkdown(marker, item, ctx)}`;
        }, "");
    }

    if (block.type === "paragraph") {
        return ctx.inlinesToMarkdown(block.children).trim();
    }

    return "";
}

/** Serialises one blockquote body line while avoiding extra indentation in code content. */
function blockquoteLineToMarkdown(line: string): string {
    if (!line) {
        return ">";
    }

    if (line.startsWith("    ")) {
        return `>${line}`;
    }

    return `> ${line}`;
}

/** Returns the separator before the next item in a Markdown list. */
function listItemSeparator(previousItem: ListItemBlock | undefined): string {
    if (previousItem && !isTightListItem(previousItem)) {
        return "\n\n";
    }

    return "\n";
}

/** Serialises one list item, preserving tight single-paragraph list Markdown. */
function listItemToMarkdown(marker: string, item: ListItemBlock, ctx: ToMarkdownContext): string {
    if (isTightListItem(item)) {
        return `${marker} ${ctx.inlinesToMarkdown(item.blocks[0].children).trim()}`;
    }

    return prefixListItemMarkdown(marker, listItemBodyToMarkdown(item.blocks, ctx));
}

/** Checks whether a list item can be serialised without child block spacing. */
function isTightListItem(
    item: ListItemBlock,
): item is ListItemBlock & { blocks: [Extract<EditorBlock, { type: "paragraph" }>] } {
    return item.blocks.length === 1 && item.blocks[0]?.type === "paragraph";
}

/** Serialises list item child blocks with Markdown list nesting spacing. */
function listItemBodyToMarkdown(blocks: EditorBlock[], ctx: ToMarkdownContext): string {
    return blocks.reduce((markdown: string, block: EditorBlock, index: number): string => {
        const separator = index === 0 ? "" : listItemBlockSeparator(block);

        return `${markdown}${separator}${ctx.blockToMarkdown(block)}`;
    }, "");
}

/** Returns the separator before a child block inside a list item. */
function listItemBlockSeparator(block: EditorBlock): string {
    if (block.type === "list") {
        return "\n";
    }

    return "\n\n";
}

/** Prefixes the first line of list-item Markdown and indents continuation lines. */
function prefixListItemMarkdown(marker: string, markdown: string): string {
    const continuationIndent = " ".repeat(marker.length + 1);
    const [firstLine, ...remainingLines] = markdown.split("\n");
    const first = `${marker} ${firstLine ?? ""}`;
    const remaining = remainingLines.map((line: string): string => `${continuationIndent}${line}`).join("\n");

    return remaining ? `${first}\n${remaining}` : first;
}

/** Serialises one built-in editor inline node to Markdown (the base extension's inline serialise-out). */
function inlineToMarkdown(node: InlineNode, ctx: ToMarkdownContext): string {
    if (node.type === "strong") {
        return `**${ctx.inlinesToMarkdown(node.children)}**`;
    }

    if (node.type === "emphasis") {
        return `*${ctx.inlinesToMarkdown(node.children)}*`;
    }

    if (node.type === "strikethrough") {
        return `~~${ctx.inlinesToMarkdown(node.children)}~~`;
    }

    if (node.type === "code") {
        return `\`${node.text}\``;
    }

    if (node.type === "link") {
        return `[${ctx.inlinesToMarkdown(node.children)}](${node.url})`;
    }

    if (node.type === "break") {
        return "\\\n";
    }

    if (node.type === "text") {
        return node.text;
    }

    return "";
}

/** Extracts a Markdown code-fence language from a DOM code class. */
function codeLanguage(element: Element): string | null {
    const languageClass = Array.from(element.classList).find((className: string): boolean =>
        className.startsWith("language-"),
    );

    if (!languageClass) {
        return null;
    }

    return languageClass.slice("language-".length);
}

/** Converts text to a text node unless it is empty. */
function textNode(text: string): InlineNode[] {
    if (text.length === 0) {
        return [];
    }

    return [
        {
            text,
            type: "text",
        },
    ];
}

/** The built-in Markdown subset, reframed as the always-present base content extension. */
const baseExtension: ContentExtension = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "base",
    renderBlock,
    renderInline,
};

registerExtension(baseExtension, { fallback: true });
