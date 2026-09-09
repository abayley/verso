import type { Code, Paragraph, Parent, Root, RootContent } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { type Plugin, unified } from "unified";
import { CALLOUT_KINDS, type CalloutKind, calloutKindFromClassName, isCalloutKind } from "./callout.js";
import type {
    ContentExtensionFor,
    ExtensionBlockInput,
    FromElementContext,
    ParseContext,
    ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock } from "./editor-model.js";

export type CollapsibleKind = CalloutKind;

/** The extension-owned payload carried on a custom collapsible block. */
interface CollapsibleData {
    collapsibleType: CollapsibleKind;
    title: string | null;
    open: boolean;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        collapsible: { block: CollapsibleData };
    }
}

/** The mdast node the collapsible remark transform produces; its body is re-parsed Markdown. */
interface CollapsibleMdast extends Parent {
    type: "collapsible";
    collapsibleType: CollapsibleKind;
    title: string | null;
    open: boolean;
    children: RootContent[];
}

declare module "mdast" {
    interface RootContentMap {
        collapsible: CollapsibleMdast;
    }
    interface BlockContentMap {
        collapsible: CollapsibleMdast;
    }
}

/**
 * The mkdocs-material collapsible marker: `???` (collapsed) or `???+` (open), a known type, and an
 * optional `"title"`, alone on the line. The four-space-indented body is a separate (code) block.
 */
const MARKER_PATTERN = new RegExp(`^(\\?\\?\\?\\+?) +(${CALLOUT_KINDS.join("|")})(?: +"([^"]*)")? *$`);

/** Re-parses a collapsible's dedented body text; carries no collapsible plugin, so bodies do not nest. */
const bodyProcessor = unified().use(remarkParse).use(remarkGfm);

/** Matches a collapsible marker line (`??? type "title"` / `???+ type`), returning its parts or null. */
export function matchCollapsibleMarker(
    text: string,
): { kind: CollapsibleKind; title: string | null; open: boolean } | null {
    const match = MARKER_PATTERN.exec(text);

    const kind = match?.[2];

    if (!match || !isCalloutKind(kind)) {
        return null;
    }

    return {
        kind,
        open: match[1] === "???+",
        title: match[3] ?? null,
    };
}

/** Reads the marker, type, and optional title from a paragraph that is exactly a collapsible marker line. */
function markerFromParagraph(
    paragraph: Paragraph,
): { kind: CollapsibleKind; title: string | null; open: boolean } | null {
    const [only] = paragraph.children;

    if (paragraph.children.length !== 1 || only?.type !== "text") {
        return null;
    }

    return matchCollapsibleMarker(only.value);
}

/** Builds a collapsible mdast node, re-parsing the indented body block's text as Markdown. */
function collapsibleFromPair(
    marker: { kind: CollapsibleKind; title: string | null; open: boolean },
    body: Code,
): CollapsibleMdast {
    const reparsed = bodyProcessor.runSync(bodyProcessor.parse(body.value)) as Root;

    return {
        children: reparsed.children,
        collapsibleType: marker.kind,
        open: marker.open,
        title: marker.title,
        type: "collapsible",
    };
}

/** Merges each `marker paragraph` + following indented-body block into one collapsible node. */
function mergeCollapsibles(children: RootContent[]): RootContent[] {
    const merged: RootContent[] = [];

    for (let index = 0; index < children.length; index += 1) {
        const node = children[index];
        const marker = node?.type === "paragraph" ? markerFromParagraph(node) : null;
        const body = children[index + 1];

        if (marker && body?.type === "code") {
            merged.push(collapsibleFromPair(marker, body));
            index += 1;

            continue;
        }

        if (node) {
            merged.push(node);
        }
    }

    return merged;
}

/** The remark plugin that recognises top-level mkdocs `???` / `???+` collapsibles. */
const remarkCollapsible: Plugin<[], Root> = () => {
    return (tree: Root): void => {
        tree.children = mergeCollapsibles(tree.children);
    };
};

// Parse: a `collapsible` mdast node (produced by the remark transform) becomes a custom collapsible block.

/** Converts a collapsible mdast node to a custom collapsible block, declining any other node. */
function blockFromMdast(node: RootContent, ctx: ParseContext): ExtensionBlockInput<"collapsible"> | null {
    if (node.type !== "collapsible") {
        return null;
    }

    return {
        children: ctx.blocksFromMdast(node.children),
        data: { collapsibleType: node.collapsibleType, open: node.open, title: node.title },
    };
}

// Serialise-in: a rendered collapsible element (the Tiptap node's DOM) becomes a custom collapsible block.

/** Recognises a `<details.markdown-collapsible>` callout element and rebuilds the custom block, else declines. */
function blockFromElement(element: Element, ctx: FromElementContext): ExtensionBlockInput<"collapsible"> | null {
    if (element.tagName !== "DETAILS" || !element.classList.contains("markdown-collapsible")) {
        return null;
    }

    const collapsibleType = calloutKindFromClassName(element.classList, "markdown-collapsible");

    if (!collapsibleType) {
        return null;
    }

    const body = element.querySelector(".markdown-collapsible-body");

    return {
        children: body ? ctx.documentFromElements(body.children).blocks : [],
        data: {
            collapsibleType,
            open: element.hasAttribute("open"),
            title: element.getAttribute("data-title"),
        },
    };
}

// Serialise-out: a custom collapsible block becomes mkdocs `???` / `???+` source with a four-space body.

/** Serialises a custom collapsible block back to mkdocs Markdown, declining any other block. */
function blockToMarkdown(data: CollapsibleData, children: EditorBlock[] | undefined, ctx: ToMarkdownContext): string {
    const { collapsibleType, title, open } = data;
    const marker = open ? "???+" : "???";
    const head = title !== null ? `${marker} ${collapsibleType} "${title}"` : `${marker} ${collapsibleType}`;
    const body = ctx.documentToMarkdown({ blocks: children ?? [] });
    const indented = body
        .split("\n")
        .map((line: string): string => (line.length > 0 ? `    ${line}` : ""))
        .join("\n");

    return `${head}\n\n${indented}`;
}

/** mkdocs-material `???` / `???+` collapsible callouts, parsed by a custom remark transform. */
export const collapsibleExtension: ContentExtensionFor<"collapsible"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    name: "collapsible",
    remarkPlugins: [remarkCollapsible],
};
