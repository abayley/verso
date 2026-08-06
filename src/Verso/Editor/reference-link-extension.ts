import type { Nodes, PhrasingContent, Root, RootContent } from "mdast";
import type { Plugin } from "unified";
import type {
    ContentExtensionFor,
    ExtensionBlockInput,
    ExtensionInlineInput,
    FromElementContext,
    ParseContext,
    ToMarkdownContext,
} from "./content-extension.js";
import type { InlineNode } from "./editor-model.js";

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

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        "reference-link": { block: ReferenceDefinitionData; inline: ReferenceLinkData };
    }
}

/** A reference's resolved destination, attached to the mdast node by the resolve transform. */
interface ResolvedReference {
    referenceTitle?: string | null;
    referenceUrl?: string;
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
function inlineFromMdast(node: PhrasingContent, ctx: ParseContext): ExtensionInlineInput<"reference-link"> | null {
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
    };
}

/** Converts an mdast definition to a custom reference-link definition block, declining any other node. */
function blockFromMdast(node: RootContent): ExtensionBlockInput<"reference-link"> | null {
    if (node.type !== "definition") {
        return null;
    }

    return {
        data: { label: node.label ?? node.identifier, title: node.title ?? null, url: node.url },
    };
}

// Serialise-in: a reference-link anchor -> custom inline; a definition element -> custom block.

/** Recognises a reference-link anchor and rebuilds the custom inline node, declining otherwise. */
function inlineFromElement(node: ChildNode, ctx: FromElementContext): ExtensionInlineInput<"reference-link">[] | null {
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
        },
    ];
}

/** Recognises a reference-link definition element and rebuilds the custom block, declining otherwise. */
function blockFromElement(element: Element): ExtensionBlockInput<"reference-link"> | null {
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
    };
}

/** Narrows a `data-reference-type` attribute to a reference form, defaulting to full. */
function referenceTypeFromAttribute(value: string | null): ReferenceType {
    return value === "collapsed" || value === "shortcut" ? value : "full";
}

// Serialise-out: a reference link -> its `[text][id]` form; a definition -> `[label]: url "title"`.

/** Serialises a reference link to its Markdown reference form, declining any other inline node. */
function inlineToMarkdown(data: ReferenceLinkData, children: InlineNode[] | undefined, ctx: ToMarkdownContext): string {
    const { label, referenceType } = data;
    const text = ctx.inlinesToMarkdown(children ?? []);

    if (referenceType === "shortcut") {
        return `[${text}]`;
    }

    if (referenceType === "collapsed") {
        return `[${text}][]`;
    }

    return `[${text}][${label}]`;
}

/** Serialises a reference-link definition to `[label]: url "title"`, declining any other block. */
function blockToMarkdown(data: ReferenceDefinitionData): string {
    const { label, url, title } = data;

    return title !== null ? `[${label}]: ${url} "${title}"` : `[${label}]: ${url}`;
}

/** GFM reference links (`[text][id]` / `[text][]` / `[text]`) and their `[id]: url` definitions. */
export const referenceLinkExtension: ContentExtensionFor<"reference-link"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "reference-link",
    remarkPlugins: [remarkResolveReferenceLinks],
};
