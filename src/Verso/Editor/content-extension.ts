import type { PhrasingContent, RootContent } from "mdast";
import type { PluggableList } from "unified";
import { baseExtension } from "./base-extension.js";
import type { EditorBlock, EditorDocument, InlineNode } from "./editor-model.js";

/** Recursion helpers handed to an extension while parsing mdast into the editor model. */
export interface ParseContext {
    blockFromMdast(node: RootContent): EditorBlock;
    blocksFromMdast(nodes: RootContent[]): EditorBlock[];
    inlineFromMdast(node: PhrasingContent): InlineNode;
    inlinesFromMdast(nodes: PhrasingContent[]): InlineNode[];
    unsupportedNode(type: string): Error;
}

/** Recursion helpers handed to an extension while reading rendered DOM into the editor model. */
export interface FromElementContext {
    blockFromElement(element: Element): EditorBlock;
    documentFromElements(elements: HTMLCollection | Element[]): EditorDocument;
    inlineFromNode(node: ChildNode): InlineNode[];
    inlinesFromElement(element: Element): InlineNode[];
}

/** Recursion helpers handed to an extension while serialising the editor model to Markdown. */
export interface ToMarkdownContext {
    blockToMarkdown(block: EditorBlock): string;
    documentToMarkdown(document: EditorDocument): string;
    inlineToMarkdown(node: InlineNode): string;
    inlinesToMarkdown(nodes: InlineNode[]): string;
}

/**
 * A content extension contributes handlers for the pipeline seams it needs. Each handler returns
 * `null` to decline a node, letting the next extension and finally the base extension try it.
 */
export interface ContentExtension {
    name: string;
    blockFromElement?(element: Element, ctx: FromElementContext): EditorBlock | null;
    blockFromMdast?(node: RootContent, ctx: ParseContext): EditorBlock | null;
    blockToMarkdown?(block: EditorBlock, ctx: ToMarkdownContext): string | null;
    inlineFromElement?(node: ChildNode, ctx: FromElementContext): InlineNode[] | null;
    inlineFromMdast?(node: PhrasingContent, ctx: ParseContext): InlineNode | null;
    inlineToMarkdown?(node: InlineNode, ctx: ToMarkdownContext): string | null;
    /** remark/unified plugins this extension installs in the parse processor. */
    remarkPlugins?: PluggableList;
}

/** The immutable document-level interface for one explicit content extension set. */
export interface ContentPipeline {
    readonly remarkPlugins: PluggableList;
    documentFromElements(elements: HTMLCollection | Element[]): EditorDocument;
    documentFromMdast(nodes: RootContent[]): EditorDocument;
    documentToMarkdown(document: EditorDocument): string;
}

/** Builds a content pipeline from ordered feature extensions and the always-last base extension. */
export function createContentPipeline(featureExtensions: readonly ContentExtension[]): ContentPipeline {
    const names = new Set<string>([baseExtension.name]);
    const duplicate = featureExtensions.find((extension: ContentExtension): boolean => {
        if (names.has(extension.name)) {
            return true;
        }

        names.add(extension.name);

        return false;
    });

    if (duplicate) {
        throw new Error(`Duplicate content extension name: ${duplicate.name}`);
    }

    const orderedExtensions = Object.freeze([...featureExtensions, baseExtension]);

    /** Builds an unsupported-node error for the current editor subset. */
    function unsupportedNode(type: string): Error {
        return new Error(`Unsupported Markdown node for editor subset: ${type}`);
    }

    /** Converts one mdast block node into an editor block. */
    function blockFromMdast(node: RootContent): EditorBlock {
        for (const extension of orderedExtensions) {
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

    /** Converts one mdast phrasing node into an editor inline node. */
    function inlineFromMdast(node: PhrasingContent): InlineNode {
        for (const extension of orderedExtensions) {
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

    /** Converts one DOM block element to an editor block. */
    function blockFromElement(element: Element): EditorBlock {
        for (const extension of orderedExtensions) {
            const block = extension.blockFromElement?.(element, fromElementContext);

            if (block != null) {
                return block;
            }
        }

        return { children: [], type: "paragraph" };
    }

    /** Builds an editor document from DOM block elements. */
    function documentFromElements(elements: HTMLCollection | Element[]): EditorDocument {
        return {
            blocks: Array.from(elements).map((element: Element): EditorBlock => blockFromElement(element)),
        };
    }

    /** Converts one inline DOM node to zero or more editor inline nodes. */
    function inlineFromNode(node: ChildNode): InlineNode[] {
        for (const extension of orderedExtensions) {
            const nodes = extension.inlineFromElement?.(node, fromElementContext);

            if (nodes != null) {
                return nodes;
            }
        }

        return [];
    }

    /** Converts an element's inline DOM children to editor inline nodes. */
    function inlinesFromElement(element: Element): InlineNode[] {
        return Array.from(element.childNodes).flatMap((node: ChildNode): InlineNode[] => inlineFromNode(node));
    }

    const fromElementContext: FromElementContext = {
        blockFromElement,
        documentFromElements,
        inlineFromNode,
        inlinesFromElement,
    };

    /** Serialises one editor block to Markdown. */
    function blockToMarkdown(block: EditorBlock): string {
        for (const extension of orderedExtensions) {
            const markdown = extension.blockToMarkdown?.(block, toMarkdownContext);

            if (markdown != null) {
                return markdown;
            }
        }

        return "";
    }

    /** Serialises an editor document to Markdown. */
    function documentToMarkdown(document: EditorDocument): string {
        return document.blocks.map((block: EditorBlock): string => blockToMarkdown(block)).join("\n\n");
    }

    /** Serialises one editor inline node to Markdown. */
    function inlineToMarkdown(node: InlineNode): string {
        for (const extension of orderedExtensions) {
            const markdown = extension.inlineToMarkdown?.(node, toMarkdownContext);

            if (markdown != null) {
                return markdown;
            }
        }

        return "";
    }

    /** Serialises editor inline nodes to Markdown. */
    function inlinesToMarkdown(nodes: InlineNode[]): string {
        return nodes.map((node: InlineNode): string => inlineToMarkdown(node)).join("");
    }

    const toMarkdownContext: ToMarkdownContext = {
        blockToMarkdown,
        documentToMarkdown,
        inlineToMarkdown,
        inlinesToMarkdown,
    };

    return Object.freeze({
        documentFromElements,
        documentFromMdast: (nodes: RootContent[]): EditorDocument => ({ blocks: blocksFromMdast(nodes) }),
        documentToMarkdown,
        remarkPlugins: Object.freeze(
            orderedExtensions.flatMap((extension: ContentExtension): PluggableList => extension.remarkPlugins ?? []),
        ) as PluggableList,
    });
}

// Temporary legacy composition. Phase 2 removes this state after all production callers receive a pipeline.
const registeredFeatureExtensions: ContentExtension[] = [];

/** Registers a feature extension in the temporary legacy production composition. */
export function registerExtension(extension: ContentExtension, options: { fallback?: boolean } = {}): void {
    if (options.fallback) {
        return;
    }

    if (
        !registeredFeatureExtensions.some((registered: ContentExtension): boolean => registered.name === extension.name)
    ) {
        registeredFeatureExtensions.push(extension);
    }
}

/** Returns the temporary legacy content pipeline. */
function registeredContentPipeline(): ContentPipeline {
    return createContentPipeline(registeredFeatureExtensions);
}

/** Collects remark plugins from the temporary legacy content pipeline. */
export function collectRemarkPlugins(): PluggableList {
    return registeredContentPipeline().remarkPlugins;
}

/** Converts one mdast block through the temporary legacy content pipeline. */
export function blockFromMdast(node: RootContent): EditorBlock {
    return registeredContentPipeline().documentFromMdast([node]).blocks[0] as EditorBlock;
}

/** Converts DOM elements through the temporary legacy content pipeline. */
export function documentFromElements(elements: HTMLCollection | Element[]): EditorDocument {
    return registeredContentPipeline().documentFromElements(elements);
}

/** Serialises an editor document through the temporary legacy content pipeline. */
export function documentToMarkdown(document: EditorDocument): string {
    return registeredContentPipeline().documentToMarkdown(document);
}
