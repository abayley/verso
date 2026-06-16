import type { PhrasingContent, RootContent } from "mdast";
import type { EditorBlock, EditorDocument, InlineNode } from "./editor-model.js";

/** Recursion helpers handed to an extension while parsing mdast into the editor model. */
export interface ParseContext {
    blockFromMdast(node: RootContent): EditorBlock;
    blocksFromMdast(nodes: RootContent[]): EditorBlock[];
    inlineFromMdast(node: PhrasingContent): InlineNode;
    inlinesFromMdast(nodes: PhrasingContent[]): InlineNode[];
    unsupportedNode(type: string): Error;
}

/** Recursion helpers handed to an extension while rendering the editor model to HTML. */
export interface RenderContext {
    escapeHtml(value: string): string;
    renderBlock(block: EditorBlock): string;
    renderBlocks(blocks: EditorBlock[]): string;
    renderInline(node: InlineNode): string;
    renderInlines(nodes: InlineNode[]): string;
}

/** Recursion helpers handed to an extension while reading rendered DOM into the editor model. */
export interface FromElementContext {
    blockFromElement(element: Element): EditorBlock;
    documentFromElements(elements: HTMLCollection | Element[]): EditorDocument;
}

/** Recursion helpers handed to an extension while serialising the editor model to Markdown. */
export interface ToMarkdownContext {
    blockToMarkdown(block: EditorBlock): string;
    documentToMarkdown(document: EditorDocument): string;
}

/**
 * A content extension contributes handlers for the pipeline seams it needs. Each handler returns
 * `null` to decline a node, letting the next extension (and finally the base extension) try it.
 */
export interface ContentExtension {
    name: string;
    blockFromElement?(element: Element, ctx: FromElementContext): EditorBlock | null;
    blockFromMdast?(node: RootContent, ctx: ParseContext): EditorBlock | null;
    blockToMarkdown?(block: EditorBlock, ctx: ToMarkdownContext): string | null;
    inlineFromMdast?(node: PhrasingContent, ctx: ParseContext): InlineNode | null;
    renderBlock?(block: EditorBlock, ctx: RenderContext): string | null;
    renderInline?(node: InlineNode, ctx: RenderContext): string | null;
}

const extensions: ContentExtension[] = [];
let fallbackExtension: ContentExtension | null = null;

/**
 * Registers a content extension. Feature extensions are consulted in registration order; the
 * fallback extension (the built-in base subset) is always consulted last.
 */
export function registerExtension(extension: ContentExtension, options: { fallback?: boolean } = {}): void {
    if (options.fallback) {
        fallbackExtension = extension;

        return;
    }

    if (!extensions.some((registered: ContentExtension): boolean => registered.name === extension.name)) {
        extensions.push(extension);
    }
}

/** Returns feature extensions in registration order, followed by the fallback extension. */
function orderedExtensions(): ContentExtension[] {
    return fallbackExtension ? [...extensions, fallbackExtension] : [...extensions];
}

/** Builds an unsupported-node error for the current editor subset. */
function unsupportedNode(type: string): Error {
    return new Error(`Unsupported Markdown node for editor subset: ${type}`);
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

// Parse seams: strict. An mdast node no extension recognises is outside the editor subset and throws.

/** Converts one mdast block node into an editor block, or throws if it is outside the subset. */
export function blockFromMdast(node: RootContent): EditorBlock {
    for (const extension of orderedExtensions()) {
        const block = extension.blockFromMdast?.(node, parseContext);

        if (block != null) {
            return block;
        }
    }

    throw unsupportedNode(node.type);
}

/** Converts mdast block nodes into editor blocks. */
function blocksFromMdast(nodes: RootContent[]): EditorBlock[] {
    return nodes.map((node: RootContent): EditorBlock => blockFromMdast(node));
}

/** Converts one mdast phrasing node into an editor inline node, or throws if it is outside the subset. */
function inlineFromMdast(node: PhrasingContent): InlineNode {
    for (const extension of orderedExtensions()) {
        const inline = extension.inlineFromMdast?.(node, parseContext);

        if (inline != null) {
            return inline;
        }
    }

    throw unsupportedNode(node.type);
}

/** Converts mdast phrasing nodes into editor inline nodes. */
function inlinesFromMdast(nodes: PhrasingContent[]): InlineNode[] {
    return nodes.map((node: PhrasingContent): InlineNode => inlineFromMdast(node));
}

const parseContext: ParseContext = {
    blockFromMdast,
    blocksFromMdast,
    inlineFromMdast,
    inlinesFromMdast,
    unsupportedNode,
};

// Render seams: fail soft. A node no extension renders is skipped rather than throwing.

/** Renders one editor block to HTML, or an empty string if no extension handles it. */
export function renderBlock(block: EditorBlock): string {
    for (const extension of orderedExtensions()) {
        const html = extension.renderBlock?.(block, renderContext);

        if (html != null) {
            return html;
        }
    }

    return "";
}

/** Renders editor blocks to HTML. */
function renderBlocks(blocks: EditorBlock[]): string {
    return blocks.map((block: EditorBlock): string => renderBlock(block)).join("");
}

/** Renders one editor inline node to HTML, or an empty string if no extension handles it. */
function renderInline(node: InlineNode): string {
    for (const extension of orderedExtensions()) {
        const html = extension.renderInline?.(node, renderContext);

        if (html != null) {
            return html;
        }
    }

    return "";
}

/** Renders editor inline nodes to HTML. */
function renderInlines(nodes: InlineNode[]): string {
    return nodes.map((node: InlineNode): string => renderInline(node)).join("");
}

const renderContext: RenderContext = {
    escapeHtml,
    renderBlock,
    renderBlocks,
    renderInline,
    renderInlines,
};

// Serialise-in seam: fail soft. The base extension treats any unrecognised element as a paragraph.

/** Converts a DOM block element to an editor block. */
function blockFromElement(element: Element): EditorBlock {
    for (const extension of orderedExtensions()) {
        const block = extension.blockFromElement?.(element, fromElementContext);

        if (block != null) {
            return block;
        }
    }

    return { children: [], type: "paragraph" };
}

/** Builds an editor document from DOM block elements. */
export function documentFromElements(elements: HTMLCollection | Element[]): EditorDocument {
    return {
        blocks: Array.from(elements).map((element: Element): EditorBlock => blockFromElement(element)),
    };
}

const fromElementContext: FromElementContext = {
    blockFromElement,
    documentFromElements,
};

// Serialise-out seam: fail soft. The base extension serialises any unrecognised block as a paragraph.

/** Serialises one editor block to Markdown, or an empty string if no extension handles it. */
function blockToMarkdown(block: EditorBlock): string {
    for (const extension of orderedExtensions()) {
        const markdown = extension.blockToMarkdown?.(block, toMarkdownContext);

        if (markdown != null) {
            return markdown;
        }
    }

    return "";
}

/** Serialises an editor document to Markdown. */
export function documentToMarkdown(document: EditorDocument): string {
    return document.blocks.map((block: EditorBlock): string => blockToMarkdown(block)).join("\n\n");
}

const toMarkdownContext: ToMarkdownContext = {
    blockToMarkdown,
    documentToMarkdown,
};
