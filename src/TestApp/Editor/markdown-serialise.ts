import type { EditorBlock, EditorDocument, InlineNode } from "./editor-model.js";

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
export function blockFromElement(block: Element): EditorBlock {
    if (block.tagName === "HR") {
        return {
            type: "horizontalRule",
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
            items: Array.from(block.children).map((item: Element): InlineNode[] => inlineNodesFromElement(item)),
            ordered: false,
            type: "list",
        };
    }

    if (block.tagName === "OL") {
        return {
            items: Array.from(block.children).map((item: Element): InlineNode[] => inlineNodesFromElement(item)),
            ordered: true,
            type: "list",
        };
    }

    return {
        children: inlineNodesFromElement(block),
        type: "paragraph",
    };
}

/** Converts child inline DOM nodes to editor inline nodes. */
export function inlineNodesFromElement(element: Element): InlineNode[] {
    return Array.from(element.childNodes).flatMap((node: ChildNode): InlineNode[] => inlineNodesFromNode(node));
}

/** Converts one inline DOM node to zero or more editor inline nodes. */
export function inlineNodesFromNode(node: ChildNode): InlineNode[] {
    if (node.nodeType === Node.TEXT_NODE) {
        return textNode(node.textContent ?? "");
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
        return [];
    }

    const element = node as Element;

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

/** Serialises one editor block to Markdown. */
function blockToMarkdown(block: EditorBlock): string {
    if (block.type === "horizontalRule") {
        return "---";
    }

    if (block.type === "heading") {
        return `${"#".repeat(block.level)} ${inlineNodesToMarkdown(block.children).trim()}`;
    }

    if (block.type === "list") {
        return block.items
            .map((item: InlineNode[], index: number): string => {
                const marker = block.ordered ? `${index + 1}.` : "-";

                return `${marker} ${inlineNodesToMarkdown(item).trim()}`;
            })
            .join("\n");
    }

    return inlineNodesToMarkdown(block.children).trim();
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

    return node.text;
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
