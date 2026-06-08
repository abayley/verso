import type { EditorBlock, EditorDocument, InlineNode, ListItemBlock } from "./editor-model.js";

/** Builds an editor document from supported DOM block elements. */
export function documentFromElements(elements: HTMLCollection | Element[]): EditorDocument {
    return {
        blocks: Array.from(elements).map((element: Element): EditorBlock => blockFromElement(element)),
    };
}

/** Serialises an editor document to Markdown. */
export function documentToMarkdown(document: EditorDocument): string {
    return document.blocks.map((block: EditorBlock): string => blockToMarkdown(block)).join("\n\n");
}

/** Converts a supported block element to an editor block. */
function blockFromElement(block: Element): EditorBlock {
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
            blocks: documentFromElements(block.children).blocks,
            type: "blockquote",
        };
    }

    if (block.tagName === "H1") {
        return {
            children: inlineNodesFromElement(block),
            level: 1,
            type: "heading",
        };
    }

    if (block.tagName === "H2") {
        return {
            children: inlineNodesFromElement(block),
            level: 2,
            type: "heading",
        };
    }

    if (block.tagName === "H3") {
        return {
            children: inlineNodesFromElement(block),
            level: 3,
            type: "heading",
        };
    }

    if (block.tagName === "UL") {
        return {
            items: Array.from(block.children).map((item: Element): ListItemBlock => listItemFromElement(item)),
            ordered: false,
            type: "list",
        };
    }

    if (block.tagName === "OL") {
        return {
            items: Array.from(block.children).map((item: Element): ListItemBlock => listItemFromElement(item)),
            ordered: true,
            type: "list",
        };
    }

    return {
        children: inlineNodesFromElement(block),
        type: "paragraph",
    };
}

/** Converts a list item element to editor item blocks. */
function listItemFromElement(item: Element): ListItemBlock {
    if (hasBlockChildren(item)) {
        return {
            blocks: documentFromElements(item.children).blocks,
        };
    }

    return {
        blocks: [
            {
                children: inlineNodesFromElement(item),
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

/** Converts child inline DOM nodes to editor inline nodes. */
function inlineNodesFromElement(element: Element): InlineNode[] {
    return Array.from(element.childNodes).flatMap((node: ChildNode): InlineNode[] => inlineNodesFromNode(node));
}

/** Converts one inline DOM node to zero or more editor inline nodes. */
function inlineNodesFromNode(node: ChildNode): InlineNode[] {
    if (node.nodeType === Node.TEXT_NODE) {
        return textNode(node.textContent ?? "");
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
        return [];
    }

    const element = node as Element;

    if (element.tagName === "BR") {
        return [
            {
                type: "break",
            },
        ];
    }

    if (element.tagName === "STRONG" || element.tagName === "B") {
        return [
            {
                children: inlineNodesFromElement(element),
                type: "strong",
            },
        ];
    }

    if (element.tagName === "EM" || element.tagName === "I") {
        return [
            {
                children: inlineNodesFromElement(element),
                type: "emphasis",
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
                children: inlineNodesFromElement(element),
                type: "link",
                url: element.getAttribute("href") ?? "",
            },
        ];
    }

    return inlineNodesFromElement(element);
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

/** Serialises one editor block to Markdown. */
function blockToMarkdown(block: EditorBlock): string {
    if (block.type === "horizontalRule") {
        return "---";
    }

    if (block.type === "codeBlock") {
        return [`\`\`\`${block.language ?? ""}`, block.text, "```"].join("\n");
    }

    if (block.type === "blockquote") {
        return documentToMarkdown({ blocks: block.blocks })
            .split("\n")
            .map((line: string): string => blockquoteLineToMarkdown(line))
            .join("\n");
    }

    if (block.type === "heading") {
        return `${"#".repeat(block.level)} ${inlineNodesToMarkdown(block.children).trim()}`;
    }

    if (block.type === "list") {
        return block.items.reduce((markdown: string, item: ListItemBlock, index: number): string => {
            const marker = block.ordered ? `${index + 1}.` : "-";
            const separator = index === 0 ? "" : listItemSeparator(block.items[index - 1]);

            return `${markdown}${separator}${listItemToMarkdown(marker, item)}`;
        }, "");
    }

    return inlineNodesToMarkdown(block.children).trim();
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
function listItemToMarkdown(marker: string, item: ListItemBlock): string {
    if (isTightListItem(item)) {
        return `${marker} ${inlineNodesToMarkdown(item.blocks[0].children).trim()}`;
    }

    return prefixListItemMarkdown(marker, listItemBodyToMarkdown(item.blocks));
}

/** Checks whether a list item can be serialised without child block spacing. */
function isTightListItem(
    item: ListItemBlock,
): item is ListItemBlock & { blocks: [Extract<EditorBlock, { type: "paragraph" }>] } {
    return item.blocks.length === 1 && item.blocks[0]?.type === "paragraph";
}

/** Serialises list item child blocks with Markdown list nesting spacing. */
function listItemBodyToMarkdown(blocks: EditorBlock[]): string {
    return blocks.reduce((markdown: string, block: EditorBlock, index: number): string => {
        const separator = index === 0 ? "" : listItemBlockSeparator(block);

        return `${markdown}${separator}${blockToMarkdown(block)}`;
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

/** Serialises editor inline nodes to Markdown. */
function inlineNodesToMarkdown(nodes: InlineNode[]): string {
    return nodes.map((node: InlineNode): string => inlineNodeToMarkdown(node)).join("");
}

/** Serialises one editor inline node to Markdown. */
function inlineNodeToMarkdown(node: InlineNode): string {
    if (node.type === "strong") {
        return `**${inlineNodesToMarkdown(node.children)}**`;
    }

    if (node.type === "emphasis") {
        return `*${inlineNodesToMarkdown(node.children)}*`;
    }

    if (node.type === "code") {
        return `\`${node.text}\``;
    }

    if (node.type === "link") {
        return `[${inlineNodesToMarkdown(node.children)}](${node.url})`;
    }

    if (node.type === "break") {
        return "\\\n";
    }

    return node.text;
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
