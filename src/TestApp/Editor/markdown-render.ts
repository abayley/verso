import type { EditorBlock, EditorDocument, InlineNode } from "./editor-model.js";
import { parseMarkdown } from "./markdown-parse.js";

/** Renders the supported Markdown subset to HTML. */
export function renderMarkdown(markdown: string): string {
    return renderEditorDocument(parseMarkdown(markdown));
}

/** Renders an editor document to HTML. */
export function renderEditorDocument(document: EditorDocument): string {
    return document.blocks.map((block: EditorBlock): string => renderBlock(block)).join("");
}

/** Renders one editor block to HTML. */
export function renderBlock(block: EditorBlock): string {
    if (block.type === "heading") {
        return `<h${block.level}>${renderInlineNodes(block.children)}</h${block.level}>`;
    }

    if (block.type === "list") {
        const tag = block.ordered ? "ol" : "ul";

        return `<${tag}>${block.items
            .map((item: InlineNode[]): string => `<li>${renderInlineNodes(item)}</li>`)
            .join("")}</${tag}>`;
    }

    return `<p>${renderInlineNodes(block.children)}</p>`;
}

/** Renders supported inline nodes to HTML. */
export function renderInlineNodes(nodes: InlineNode[]): string {
    return nodes.map((node: InlineNode): string => renderInlineNode(node)).join("");
}

/** Renders one supported inline node to HTML. */
export function renderInlineNode(node: InlineNode): string {
    if (node.type === "strong") {
        return `<strong>${renderInlineNodes(node.children)}</strong>`;
    }

    if (node.type === "emphasis") {
        return `<em>${renderInlineNodes(node.children)}</em>`;
    }

    if (node.type === "code") {
        return `<code>${escapeHtml(node.text)}</code>`;
    }

    if (node.type === "link") {
        return `<a href="${escapeHtml(node.url)}">${renderInlineNodes(node.children)}</a>`;
    }

    return escapeHtml(node.text);
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
