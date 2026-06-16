import type { Nodes, PhrasingContent, Root, RootContent } from "mdast";
import type { Plugin } from "unified";
import {
    type ContentExtension,
    type FromElementContext,
    type ParseContext,
    type RenderContext,
    registerExtension,
    type ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock, InlineNode } from "./editor-model.js";

/** A reference link's form: full `[text][id]`, collapsed `[text][]`, or shortcut `[text]`. */
type ReferenceType = "full" | "collapsed" | "shortcut";

/** The payload on a custom reference-link inline node (the reference itself). */
interface ReferenceLinkData {
    label: string;
    referenceType: ReferenceType;
    title: string | null;
    url: string;
}

/** The payload on a custom reference-link block node (the link reference definition). */
interface ReferenceDefinitionData {
    label: string;
    title: string | null;
    url: string;
}

/** A reference's resolved destination, attached to the mdast node by the resolve transform. */
interface ResolvedReference {
    referenceTitle?: string | null;
    referenceUrl?: string;
}

/** Whether an editor block is a reference-link definition. */
function isReferenceDefinition(block: EditorBlock): block is EditorBlock & { extension: string; data: unknown } {
    return block.type === "custom" && block.extension === "reference-link";
}

/** Whether an editor inline node is a reference link. */
function isReferenceLink(
    node: InlineNode,
): node is InlineNode & { extension: string; data: unknown; children?: InlineNode[] } {
    return node.type === "custom" && node.extension === "reference-link";
}

/** Walks every node in an mdast tree, applying a visitor. */
function walk(node: Nodes, visit: (node: Nodes) => void): void {
    visit(node);

    if ("children" in node) {
        for (const child of node.children) {
            walk(child, visit);
        }
    }
}

/**
 * Resolves each `linkReference` to its `definition`'s URL and title, attaching them to the node for the
 * render seam. A `linkReference` only exists when a matching definition does (remark leaves an
 * unresolved reference as literal text), so every reference resolves.
 */
const remarkResolveReferenceLinks: Plugin<[], Root> = () => {
    return (tree: Root): void => {
        const definitions = new Map<string, { title: string | null; url: string }>();

        walk(tree, (node: Nodes): void => {
            if (node.type === "definition") {
                definitions.set(node.identifier, { title: node.title ?? null, url: node.url });
            }
        });

        walk(tree, (node: Nodes): void => {
            if (node.type === "linkReference") {
                const resolved = definitions.get(node.identifier);
                node.data = {
                    ...node.data,
                    referenceTitle: resolved?.title ?? null,
                    referenceUrl: resolved?.url ?? "",
                };
            }
        });
    };
};

// Parse: linkReference -> custom reference-link inline; definition -> custom reference-link block.

/** Converts an mdast link reference to a custom reference-link inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent, ctx: ParseContext): InlineNode | null {
    if (node.type !== "linkReference") {
        return null;
    }

    const resolved = node.data as ResolvedReference | undefined;

    return {
        children: ctx.inlinesFromMdast(node.children),
        data: {
            label: node.label ?? node.identifier,
            referenceType: node.referenceType,
            title: resolved?.referenceTitle ?? null,
            url: resolved?.referenceUrl ?? "",
        },
        extension: "reference-link",
        type: "custom",
    };
}

/** Converts an mdast definition to a custom reference-link definition block, declining any other node. */
function blockFromMdast(node: RootContent): EditorBlock | null {
    if (node.type !== "definition") {
        return null;
    }

    return {
        data: { label: node.label ?? node.identifier, title: node.title ?? null, url: node.url },
        extension: "reference-link",
        type: "custom",
    };
}

// Render: a reference link resolves to an anchor; a definition renders nothing (it is invisible markup).

/** Renders a reference link to a resolved anchor, declining any other inline node. */
function renderInline(node: InlineNode, ctx: RenderContext): string | null {
    if (!isReferenceLink(node)) {
        return null;
    }

    const { url, title } = node.data as ReferenceLinkData;
    const titleAttr = title !== null ? ` title="${ctx.escapeHtml(title)}"` : "";

    return `<a href="${ctx.escapeHtml(url)}"${titleAttr}>${ctx.renderInlines(node.children ?? [])}</a>`;
}

/** A reference-link definition produces no rendered output, declining any other block. */
function renderBlock(block: EditorBlock): string | null {
    return isReferenceDefinition(block) ? "" : null;
}

// Serialise-in: a reference-link anchor -> custom inline; a definition element -> custom block.

/** Recognises a reference-link anchor and rebuilds the custom inline node, declining otherwise. */
function inlineFromElement(node: ChildNode, ctx: FromElementContext): InlineNode[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (element.tagName !== "A" || !element.classList.contains("markdown-reference-link")) {
        return null;
    }

    const label = element.getAttribute("data-reference-label");

    if (label === null) {
        return null;
    }

    return [
        {
            children: ctx.inlinesFromElement(element),
            data: {
                label,
                referenceType: referenceTypeFromAttribute(element.getAttribute("data-reference-type")),
                title: element.getAttribute("title"),
                url: element.getAttribute("href") ?? "",
            },
            extension: "reference-link",
            type: "custom",
        },
    ];
}

/** Recognises a reference-link definition element and rebuilds the custom block, declining otherwise. */
function blockFromElement(element: Element): EditorBlock | null {
    if (element.tagName !== "DIV" || !element.classList.contains("markdown-reference-def")) {
        return null;
    }

    const label = element.getAttribute("data-reference-label");

    if (label === null) {
        return null;
    }

    return {
        data: {
            label,
            title: element.getAttribute("data-reference-title"),
            url: element.getAttribute("data-reference-url") ?? "",
        },
        extension: "reference-link",
        type: "custom",
    };
}

/** Narrows a `data-reference-type` attribute to a reference form, defaulting to full. */
function referenceTypeFromAttribute(value: string | null): ReferenceType {
    return value === "collapsed" || value === "shortcut" ? value : "full";
}

// Serialise-out: a reference link -> its `[text][id]` form; a definition -> `[label]: url "title"`.

/** Serialises a reference link to its Markdown reference form, declining any other inline node. */
function inlineToMarkdown(node: InlineNode, ctx: ToMarkdownContext): string | null {
    if (!isReferenceLink(node)) {
        return null;
    }

    const { label, referenceType } = node.data as ReferenceLinkData;
    const text = ctx.inlinesToMarkdown(node.children ?? []);

    if (referenceType === "shortcut") {
        return `[${text}]`;
    }

    if (referenceType === "collapsed") {
        return `[${text}][]`;
    }

    return `[${text}][${label}]`;
}

/** Serialises a reference-link definition to `[label]: url "title"`, declining any other block. */
function blockToMarkdown(block: EditorBlock): string | null {
    if (!isReferenceDefinition(block)) {
        return null;
    }

    const { label, url, title } = block.data as ReferenceDefinitionData;

    return title !== null ? `[${label}]: ${url} "${title}"` : `[${label}]: ${url}`;
}

/** GFM reference links (`[text][id]` / `[text][]` / `[text]`) and their `[id]: url` definitions. */
const referenceLinkExtension: ContentExtension = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "reference-link",
    remarkPlugins: [remarkResolveReferenceLinks],
    renderBlock,
    renderInline,
};

registerExtension(referenceLinkExtension);
