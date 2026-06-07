/** Serialises a supported block element to Markdown. */
export function blockToMarkdown(block: Element): string {
    const text = inlineNodesToMarkdown(block).trim();

    if (block.tagName === "H1") {
        return `# ${text}`;
    }

    if (block.tagName === "H2") {
        return `## ${text}`;
    }

    if (block.tagName === "H3") {
        return `### ${text}`;
    }

    if (block.tagName === "UL") {
        return Array.from(block.children)
            .map((item: Element): string => `- ${inlineNodesToMarkdown(item).trim()}`)
            .join("\n");
    }

    if (block.tagName === "OL") {
        return Array.from(block.children)
            .map((item: Element, index: number): string => `${index + 1}. ${inlineNodesToMarkdown(item).trim()}`)
            .join("\n");
    }

    return text;
}

/** Serialises child inline nodes to Markdown. */
export function inlineNodesToMarkdown(element: Element): string {
    return Array.from(element.childNodes)
        .map((node: ChildNode): string => inlineNodeToMarkdown(node))
        .join("");
}

/** Serialises one inline node to Markdown. */
export function inlineNodeToMarkdown(node: ChildNode): string {
    if (node.nodeType === Node.TEXT_NODE) {
        return node.textContent ?? "";
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
        return "";
    }

    const element = node as Element;

    if (element.tagName === "STRONG" || element.tagName === "B") {
        return `**${inlineNodesToMarkdown(element)}**`;
    }

    if (element.tagName === "EM" || element.tagName === "I") {
        return `*${inlineNodesToMarkdown(element)}*`;
    }

    if (element.tagName === "CODE") {
        return `\`${(element as HTMLElement).innerText}\``;
    }

    if (element.tagName === "A") {
        return `[${inlineNodesToMarkdown(element)}](${element.getAttribute("href") ?? ""})`;
    }

    return inlineNodesToMarkdown(element);
}
