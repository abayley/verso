import type { EditorBlock, EditorDocument, InlineNode, ListItemBlock } from "./editor-model.js";
import { parseMarkdown } from "./markdown-parse.js";

/** Renders the supported Markdown subset to HTML. */
export function renderMarkdown(markdown: string): string {
    return renderEditorDocument(parseMarkdown(markdown));
}

/** Renders an editor document to HTML. */
function renderEditorDocument(document: EditorDocument): string {
    return document.blocks.map((block: EditorBlock): string => renderBlock(block)).join("");
}

/** Renders one editor block to HTML. */
function renderBlock(block: EditorBlock): string {
    if (block.type === "heading") {
        return `<h${block.level}>${renderInlineNodes(block.children)}</h${block.level}>`;
    }

    if (block.type === "list") {
        const tag = block.ordered ? "ol" : "ul";

        return `<${tag}>${block.items.map((item: ListItemBlock): string => renderListItem(item)).join("")}</${tag}>`;
    }

    if (block.type === "horizontalRule") {
        return "<hr>";
    }

    if (block.type === "codeBlock") {
        const languageClass = block.language ? ` class="language-${escapeHtml(block.language)}"` : "";

        return `<pre><code${languageClass}>${escapeHtml(block.text)}</code></pre>`;
    }

    if (block.type === "blockquote") {
        return `<blockquote>${block.blocks.map((child: EditorBlock): string => renderBlock(child)).join("")}</blockquote>`;
    }

    return `<p>${renderInlineNodes(block.children)}</p>`;
}

/** Renders one list item, keeping tight single-paragraph items compact. */
function renderListItem(item: ListItemBlock): string {
    if (item.blocks.length === 1 && item.blocks[0]?.type === "paragraph") {
        return `<li>${renderInlineNodes(item.blocks[0].children)}</li>`;
    }

    return `<li>${item.blocks.map((child: EditorBlock): string => renderBlock(child)).join("")}</li>`;
}

/** Renders supported inline nodes to HTML. */
function renderInlineNodes(nodes: InlineNode[]): string {
    return nodes.map((node: InlineNode): string => renderInlineNode(node)).join("");
}

/** Renders one supported inline node to HTML. */
function renderInlineNode(node: InlineNode): string {
    if (node.type === "strong") {
        return `<strong>${renderInlineNodes(node.children)}</strong>`;
    }

    if (node.type === "emphasis") {
        return `<em>${renderInlineNodes(node.children)}</em>`;
    }

    if (node.type === "strikethrough") {
        return `<del>${renderInlineNodes(node.children)}</del>`;
    }

    if (node.type === "code") {
        return `<code>${escapeHtml(node.text)}</code>`;
    }

    if (node.type === "link") {
        return `<a href="${escapeHtml(node.url)}">${renderInlineNodes(node.children)}</a>`;
    }

    if (node.type === "break") {
        return "<br>";
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
