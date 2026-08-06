import type { PhrasingContent, RootContent } from "mdast";
import type { PluggableList } from "unified";
import { baseExtension } from "./base-extension.js";
import type {
    ContentExtensionBlockPayload,
    ContentExtensionInlinePayload,
    ContentExtensionName,
    ContentExtensionPayloads,
    CustomBlock,
    CustomInline,
    EditorBlock,
    EditorDocument,
    InlineNode,
} from "./editor-model.js";

type DeclaredContentExtensionName = keyof ContentExtensionPayloads & string;

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
export interface ContentExtensionFor<Name extends DeclaredContentExtensionName> {
    name: Name;
    blockFromElement?(element: Element, ctx: FromElementContext): ExtensionBlockInput<Name> | null;
    blockFromMdast?(node: RootContent, ctx: ParseContext): ExtensionBlockInput<Name> | null;
    blockToMarkdown?(
        data: ContentExtensionBlockPayload<Name>,
        children: EditorBlock[] | undefined,
        ctx: ToMarkdownContext,
    ): string;
    inlineFromElement?(node: ChildNode, ctx: FromElementContext): ExtensionInlineInput<Name>[] | null;
    inlineFromMdast?(node: PhrasingContent, ctx: ParseContext): ExtensionInlineInput<Name> | null;
    inlineToMarkdown?(
        data: ContentExtensionInlinePayload<Name>,
        children: InlineNode[] | undefined,
        ctx: ToMarkdownContext,
    ): string;
    /** remark/unified plugins this extension installs in the parse processor. */
    remarkPlugins?: PluggableList;
}

/** Any descriptor contributed to the open content extension payload map. */
export type ContentExtension = {
    [Name in ContentExtensionName]: ContentExtensionFor<Name>;
}[ContentExtensionName];

/** An extension block payload and its optional nested blocks before the pipeline stamps identity. */
export interface ExtensionBlockInput<Name extends ContentExtensionName> {
    children?: EditorBlock[];
    data: ContentExtensionBlockPayload<Name>;
}

/** An extension inline payload and its optional nested inlines before the pipeline stamps identity. */
export interface ExtensionInlineInput<Name extends ContentExtensionName> {
    children?: InlineNode[];
    data: ContentExtensionInlinePayload<Name>;
}

/** The private built-in subset descriptor installed last by every content pipeline. */
export interface BaseContentExtension {
    name: "base";
    blockFromElement(element: Element, ctx: FromElementContext): EditorBlock;
    blockFromMdast(node: RootContent, ctx: ParseContext): EditorBlock | null;
    blockToMarkdown(block: EditorBlock, ctx: ToMarkdownContext): string;
    inlineFromElement(node: ChildNode, ctx: FromElementContext): InlineNode[];
    inlineFromMdast(node: PhrasingContent, ctx: ParseContext): InlineNode | null;
    inlineToMarkdown(node: InlineNode, ctx: ToMarkdownContext): string;
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

    const extensions = Object.freeze([...featureExtensions]);
    const extensionsByName = new Map(
        extensions.map((extension: ContentExtension): readonly [ContentExtensionName, ContentExtension] => [
            extension.name,
            extension,
        ]),
    );

    /** Builds an unsupported-node error for the current editor subset. */
    function unsupportedNode(type: string): Error {
        return new Error(`Unsupported Markdown node for editor subset: ${type}`);
    }

    /** Converts one mdast block node into an editor block. */
    function blockFromMdast(node: RootContent): EditorBlock {
        for (const extension of extensions) {
            const input = extension.blockFromMdast?.(node, parseContext);

            if (input != null) {
                return {
                    ...(input.children ? { children: input.children } : {}),
                    data: input.data,
                    extension: extension.name,
                    type: "custom",
                } as CustomBlock;
            }
        }

        const block = baseExtension.blockFromMdast(node, parseContext);

        if (block != null) {
            return block;
        }

        throw unsupportedNode(node.type);
    }

    /** Converts mdast block nodes into editor blocks. */
    function blocksFromMdast(nodes: RootContent[]): EditorBlock[] {
        return nodes.map((node: RootContent): EditorBlock => blockFromMdast(node));
    }

    /** Converts one mdast phrasing node into an editor inline node. */
    function inlineFromMdast(node: PhrasingContent): InlineNode {
        for (const extension of extensions) {
            const input = extension.inlineFromMdast?.(node, parseContext);

            if (input != null) {
                return {
                    ...(input.children ? { children: input.children } : {}),
                    data: input.data,
                    extension: extension.name,
                    type: "custom",
                } as CustomInline;
            }
        }

        const inline = baseExtension.inlineFromMdast(node, parseContext);

        if (inline != null) {
            return inline;
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
        for (const extension of extensions) {
            const input = extension.blockFromElement?.(element, fromElementContext);

            if (input != null) {
                return {
                    ...(input.children ? { children: input.children } : {}),
                    data: input.data,
                    extension: extension.name,
                    type: "custom",
                } as CustomBlock;
            }
        }

        return baseExtension.blockFromElement(element, fromElementContext);
    }

    /** Builds an editor document from DOM block elements. */
    function documentFromElements(elements: HTMLCollection | Element[]): EditorDocument {
        return {
            blocks: Array.from(elements).map((element: Element): EditorBlock => blockFromElement(element)),
        };
    }

    /** Converts one inline DOM node to zero or more editor inline nodes. */
    function inlineFromNode(node: ChildNode): InlineNode[] {
        for (const extension of extensions) {
            const inputs = extension.inlineFromElement?.(node, fromElementContext);

            if (inputs != null) {
                return inputs.map(
                    (input): CustomInline =>
                        ({
                            ...(input.children ? { children: input.children } : {}),
                            data: input.data,
                            extension: extension.name,
                            type: "custom",
                        }) as CustomInline,
                );
            }
        }

        return baseExtension.inlineFromElement(node, fromElementContext);
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
        if (block.type === "custom") {
            return (
                extensionsByName
                    .get(block.extension)
                    ?.blockToMarkdown?.(block.data as never, block.children, toMarkdownContext) ?? ""
            );
        }

        return baseExtension.blockToMarkdown(block, toMarkdownContext);
    }

    /** Serialises an editor document to Markdown. */
    function documentToMarkdown(document: EditorDocument): string {
        return document.blocks.map((block: EditorBlock): string => blockToMarkdown(block)).join("\n\n");
    }

    /** Serialises one editor inline node to Markdown. */
    function inlineToMarkdown(node: InlineNode): string {
        if (node.type === "custom") {
            return (
                extensionsByName
                    .get(node.extension)
                    ?.inlineToMarkdown?.(node.data as never, node.children, toMarkdownContext) ?? ""
            );
        }

        return baseExtension.inlineToMarkdown(node, toMarkdownContext);
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
            extensions.flatMap((extension: ContentExtension): PluggableList => extension.remarkPlugins ?? []),
        ) as PluggableList,
    });
}
