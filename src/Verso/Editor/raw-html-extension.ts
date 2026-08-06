import type { PhrasingContent, RootContent } from "mdast";
import type { ContentExtensionFor, ExtensionBlockInput, ExtensionInlineInput } from "./content-extension.js";

// Raw-HTML passthrough for the trusted document tree. The editor's strict parse otherwise throws on an
// `html` mdast node (ADR-040/041). Raw HTML -- almost always export metadata comments (`<!-- ... -->`),
// occasionally visible markup like MkDocs grid cards -- is carried through verbatim and shown inert
// (escaped, never rendered as live HTML), so editing a document never loses or executes its HTML.

/** The payload on a preserved raw-HTML node: the verbatim HTML text. */
interface RawHtmlData {
    html: string;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        "raw-html": { block: RawHtmlData; inline: RawHtmlData };
    }
}

/**
 * Whether a preserved raw-HTML fragment is wholly an HTML comment (`<!-- ... -->`). Comments are export
 * metadata, so they are preserved verbatim for the round-trip but hidden from view (RFC-0019 follow-up),
 * unlike other raw HTML which stays inert-but-visible.
 */
export function isHtmlComment(html: string): boolean {
    const trimmed = html.trim();

    return trimmed.startsWith("<!--") && trimmed.endsWith("-->");
}

// Parse: an mdast `html` node (block or inline) -> a preserved raw-html node carrying its verbatim text.

/** Converts a block-level mdast `html` node to a preserved raw-html block, declining any other node. */
function blockFromMdast(node: RootContent): ExtensionBlockInput<"raw-html"> | null {
    return node.type === "html" ? { data: { html: node.value } } : null;
}

/** Converts an inline mdast `html` node to a preserved raw-html inline, declining any other node. */
function inlineFromMdast(node: PhrasingContent): ExtensionInlineInput<"raw-html"> | null {
    return node.type === "html" ? { data: { html: node.value } } : null;
}

// Serialise-in: a `.markdown-raw-html` placeholder element -> a preserved raw-html node. The element's text
// content is the verbatim HTML (the browser decodes the escaped render back to the original text).

/** Recognises a raw-html placeholder block element and rebuilds the preserved block, declining otherwise. */
function blockFromElement(element: Element): ExtensionBlockInput<"raw-html"> | null {
    if (element.tagName !== "DIV" || !element.classList.contains("markdown-raw-html")) {
        return null;
    }

    return { data: { html: element.textContent ?? "" } };
}

/** Recognises a raw-html placeholder inline element and rebuilds the preserved inline, declining otherwise. */
function inlineFromElement(node: ChildNode): ExtensionInlineInput<"raw-html">[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (!element.classList.contains("markdown-raw-html")) {
        return null;
    }

    return [{ data: { html: element.textContent ?? "" } }];
}

// Serialise-out: the verbatim HTML, unchanged.

/** Serialises a preserved raw-html block to its verbatim HTML, declining any other block. */
function blockToMarkdown(data: RawHtmlData): string {
    return data.html;
}

/** Serialises a preserved raw-html inline to its verbatim HTML, declining any other inline. */
function inlineToMarkdown(data: RawHtmlData): string {
    return data.html;
}

/** Preserves raw HTML verbatim and shows it inert; registered only in the trusted document-tree mode. */
export const rawHtmlExtension: ContentExtensionFor<"raw-html"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "raw-html",
};
