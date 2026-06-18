import type { PhrasingContent, RootContent } from "mdast";
import type { ContentExtension, RenderContext } from "./content-extension.js";
import type { EditorBlock, InlineNode } from "./editor-model.js";

// Raw-HTML passthrough (opt-in, for the trusted document-tree editing mode). The editor's strict parse
// otherwise throws on an `html` mdast node (ADR-040/041 reject raw HTML in the untrusted flat mode). Here
// raw HTML -- almost always export metadata comments (`<!-- ... -->`), occasionally visible markup like
// MkDocs grid cards -- is carried through verbatim and shown inert (escaped, never rendered as live HTML),
// so editing a document never loses or executes its HTML. This extension is registered by the editor only
// in tree mode; the flat mode keeps rejecting raw HTML, so the save-time trust boundary is unchanged.

/** The payload on a preserved raw-HTML node: the verbatim HTML text. */
interface RawHtmlData {
    html: string;
}

/** Whether an editor block is preserved raw HTML. */
function isRawHtmlBlock(block: EditorBlock): block is EditorBlock & { data: RawHtmlData } {
    return block.type === "custom" && block.extension === "raw-html";
}

/** Whether an editor inline node is preserved raw HTML. */
function isRawHtmlInline(node: InlineNode): node is InlineNode & { data: RawHtmlData } {
    return node.type === "custom" && node.extension === "raw-html";
}

// Parse: an mdast `html` node (block or inline) -> a preserved raw-html node carrying its verbatim text.

/** Converts a block-level mdast `html` node to a preserved raw-html block, declining any other node. */
function blockFromMdast(node: RootContent): EditorBlock | null {
    return node.type === "html" ? { data: { html: node.value }, extension: "raw-html", type: "custom" } : null;
}

/** Converts an inline mdast `html` node to a preserved raw-html inline, declining any other node. */
function inlineFromMdast(node: PhrasingContent): InlineNode | null {
    return node.type === "html" ? { data: { html: node.value }, extension: "raw-html", type: "custom" } : null;
}

// Render: inert. The verbatim HTML is shown escaped (so it is visible-but-not-rendered) and carried as the
// element's text content, which the DOM serialise seam reads straight back.

/** Renders a preserved raw-html block as an inert, escaped placeholder, declining any other block. */
function renderBlock(block: EditorBlock, ctx: RenderContext): string | null {
    if (!isRawHtmlBlock(block)) {
        return null;
    }

    return `<div class="markdown-raw-html">${ctx.escapeHtml(block.data.html)}</div>`;
}

/** Renders a preserved raw-html inline as an inert, escaped placeholder, declining any other inline. */
function renderInline(node: InlineNode, ctx: RenderContext): string | null {
    if (!isRawHtmlInline(node)) {
        return null;
    }

    return `<span class="markdown-raw-html">${ctx.escapeHtml(node.data.html)}</span>`;
}

// Serialise-in: a `.markdown-raw-html` placeholder element -> a preserved raw-html node. The element's text
// content is the verbatim HTML (the browser decodes the escaped render back to the original text).

/** Recognises a raw-html placeholder block element and rebuilds the preserved block, declining otherwise. */
function blockFromElement(element: Element): EditorBlock | null {
    if (element.tagName !== "DIV" || !element.classList.contains("markdown-raw-html")) {
        return null;
    }

    return { data: { html: element.textContent ?? "" }, extension: "raw-html", type: "custom" };
}

/** Recognises a raw-html placeholder inline element and rebuilds the preserved inline, declining otherwise. */
function inlineFromElement(node: ChildNode): InlineNode[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (!element.classList.contains("markdown-raw-html")) {
        return null;
    }

    return [{ data: { html: element.textContent ?? "" }, extension: "raw-html", type: "custom" }];
}

// Serialise-out: the verbatim HTML, unchanged.

/** Serialises a preserved raw-html block to its verbatim HTML, declining any other block. */
function blockToMarkdown(block: EditorBlock): string | null {
    return isRawHtmlBlock(block) ? block.data.html : null;
}

/** Serialises a preserved raw-html inline to its verbatim HTML, declining any other inline. */
function inlineToMarkdown(node: InlineNode): string | null {
    return isRawHtmlInline(node) ? node.data.html : null;
}

/** Preserves raw HTML verbatim and shows it inert; registered only in the trusted document-tree mode. */
export const rawHtmlExtension: ContentExtension = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "raw-html",
    renderBlock,
    renderInline,
};
