import type { PhrasingContent } from "mdast";
import {
    type ContentExtension,
    type FromElementContext,
    type ParseContext,
    type RenderContext,
    registerExtension,
    type ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock, InlineNode } from "./editor-model.js";

/** The payload on a custom image inline node. */
interface ImageData {
    alt: string;
    src: string;
    title: string | null;
}

/** Whether an editor inline node is an image. */
function isImage(node: InlineNode): node is InlineNode & { data: unknown } {
    return node.type === "custom" && node.extension === "image";
}

// Parse: an mdast image -> a custom image inline.

/** Converts an mdast image to a custom image inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent, _ctx: ParseContext): InlineNode | null {
    if (node.type !== "image") {
        return null;
    }

    return {
        data: { alt: node.alt ?? "", src: node.url, title: node.title ?? null },
        extension: "image",
        type: "custom",
    };
}

// Render: an image -> an <img> element with escaped attributes.

/** Renders an image to an `<img>` element, declining any other inline node. */
function renderInline(node: InlineNode, ctx: RenderContext): string | null {
    if (!isImage(node)) {
        return null;
    }

    const { alt, src, title } = node.data as ImageData;
    const titleAttr = title !== null ? ` title="${ctx.escapeHtml(title)}"` : "";

    return `<img src="${ctx.escapeHtml(src)}" alt="${ctx.escapeHtml(alt)}"${titleAttr}>`;
}

// Serialise-in: an <img> element -> a custom image inline.

/** Builds a custom image inline node from an `<img>` element. */
function imageInlineFromElement(element: Element): InlineNode {
    return {
        data: {
            alt: element.getAttribute("alt") ?? "",
            src: element.getAttribute("src") ?? "",
            title: element.getAttribute("title"),
        },
        extension: "image",
        type: "custom",
    };
}

/** Recognises an `<img>` element and rebuilds the custom image inline, declining otherwise. */
function inlineFromElement(node: ChildNode): InlineNode[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (element.tagName !== "IMG") {
        return null;
    }

    // ProseMirror inserts <img class="ProseMirror-separator"> beside an inline atom for cursor placement;
    // it is an editor artifact (like the trailing <br>), not content, so it must not serialise as an image.
    if (element.classList.contains("ProseMirror-separator")) {
        return [];
    }

    return [imageInlineFromElement(element)];
}

/**
 * Claims a block-level `<img>` (the visual editor renders a standalone `![](url)` as a bare top-level
 * image rather than wrapping it in a paragraph) as a paragraph holding the image, declining otherwise.
 * Without this the base extension would treat the childless `<img>` as an empty paragraph and drop it.
 */
function blockFromElement(element: Element, _ctx: FromElementContext): EditorBlock | null {
    if (element.tagName !== "IMG") {
        return null;
    }

    return {
        children: [imageInlineFromElement(element)],
        type: "paragraph",
    };
}

// Serialise-out: an image -> its `![alt](src "title")` form.

/** Serialises an image to its Markdown image form, declining any other inline node. */
function inlineToMarkdown(node: InlineNode, _ctx: ToMarkdownContext): string | null {
    if (!isImage(node)) {
        return null;
    }

    const { alt, src, title } = node.data as ImageData;
    const destination = title !== null ? `${src} "${title}"` : src;

    return `![${alt}](${destination})`;
}

/** GFM images (`![alt](src "title")`) rendered inline as `<img>`; raw HTML is never introduced. */
const imageExtension: ContentExtension = {
    blockFromElement,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "image",
    renderInline,
};

registerExtension(imageExtension);
