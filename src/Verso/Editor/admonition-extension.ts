import type { Blockquote, Paragraph, PhrasingContent, RootContent, Text } from "mdast";
import type {
    ContentExtensionFor,
    ExtensionBlockInput,
    FromElementContext,
    ParseContext,
    ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock } from "./editor-model.js";

/** The GFM alert kinds recognised as admonitions. */
export const ADMONITION_KINDS = ["note", "tip", "important", "warning", "caution"] as const;

export type AdmonitionKind = (typeof ADMONITION_KINDS)[number];

/** The extension-owned payload carried on a custom admonition block. */
interface AdmonitionData {
    kind: AdmonitionKind;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        admonition: { block: AdmonitionData };
    }
}

const MARKER_PATTERN = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\n|$)/;

/** Title-cases an admonition kind for the rendered callout heading. */
export function admonitionTitle(kind: AdmonitionKind): string {
    return kind.charAt(0).toUpperCase() + kind.slice(1);
}

/** Matches a leading GFM alert marker (`[!NOTE]` on its own line), returning the kind and match length. */
export function matchAlertMarker(text: string): { kind: AdmonitionKind; length: number } | null {
    const match = MARKER_PATTERN.exec(text);
    const kind = match?.[1]?.toLowerCase();

    if (!match || !kind) {
        return null;
    }

    return {
        kind: kind as AdmonitionKind,
        length: match[0].length,
    };
}

/** Returns the admonition kind named by a `markdown-alert-<kind>` class, or null. */
export function kindFromClassName(classes: DOMTokenList): AdmonitionKind | null {
    return ADMONITION_KINDS.find((kind: AdmonitionKind): boolean => classes.contains(`markdown-alert-${kind}`)) ?? null;
}

// Parse: a blockquote whose first line is a GFM alert marker becomes a custom admonition block.

/** Recognises a GFM alert blockquote and converts it to a custom admonition block, declining otherwise. */
function blockFromMdast(node: RootContent, ctx: ParseContext): ExtensionBlockInput<"admonition"> | null {
    if (node.type !== "blockquote") {
        return null;
    }

    const marker = alertMarker(node);

    if (!marker) {
        return null;
    }

    return {
        children: ctx.blocksFromMdast(bodyAfterMarker(node, marker.length)),
        data: { kind: marker.kind },
    };
}

/** Returns the alert kind and matched marker length when a blockquote opens with a GFM alert marker. */
function alertMarker(node: Blockquote): { kind: AdmonitionKind; length: number } | null {
    const firstParagraph = node.children[0];

    if (firstParagraph?.type !== "paragraph") {
        return null;
    }

    const firstInline = firstParagraph.children[0];

    if (firstInline?.type !== "text") {
        return null;
    }

    return matchAlertMarker(firstInline.value);
}

/** Returns the blockquote body with the marker stripped from the leading paragraph. */
function bodyAfterMarker(node: Blockquote, markerLength: number): RootContent[] {
    const [firstParagraph, ...rest] = node.children;
    const paragraph = firstParagraph as Paragraph;
    const [markerText, ...otherInline] = paragraph.children;
    const bodyText = (markerText as Text).value.slice(markerLength);

    const leadingInline: PhrasingContent[] =
        bodyText.length > 0 ? [{ type: "text", value: bodyText }, ...otherInline] : otherInline;

    if (leadingInline.length === 0) {
        return rest;
    }

    return [{ children: leadingInline, type: "paragraph" }, ...rest];
}

// Serialise-in: a rendered callout element (the Tiptap node's DOM) becomes a custom admonition block.

/** Recognises a `.markdown-alert` callout element and rebuilds the custom admonition block, declining otherwise. */
function blockFromElement(element: Element, ctx: FromElementContext): ExtensionBlockInput<"admonition"> | null {
    if (element.tagName !== "DIV" || !element.classList.contains("markdown-alert")) {
        return null;
    }

    const kind = kindFromClassName(element.classList);

    if (!kind) {
        return null;
    }

    const body = element.querySelector(".markdown-alert-body");

    return {
        children: body ? ctx.documentFromElements(body.children).blocks : [],
        data: { kind },
    };
}

// Serialise-out: a custom admonition block becomes a GFM alert blockquote.

/** Serialises a custom admonition block back to GFM alert Markdown, declining any other block. */
function blockToMarkdown(data: AdmonitionData, children: EditorBlock[] | undefined, ctx: ToMarkdownContext): string {
    const { kind } = data;
    const body = ctx.documentToMarkdown({ blocks: children ?? [] });
    const lines = body.length > 0 ? [`[!${kind.toUpperCase()}]`, ...body.split("\n")] : [`[!${kind.toUpperCase()}]`];

    return lines.map((line: string): string => alertLineToMarkdown(line)).join("\n");
}

/** Quotes one alert body line, leaving indented code content unspaced. */
function alertLineToMarkdown(line: string): string {
    if (!line) {
        return ">";
    }

    if (line.startsWith("    ")) {
        return `>${line}`;
    }

    return `> ${line}`;
}

/** GFM alert blockquotes (`> [!NOTE]`) recognised and styled as callouts. */
export const admonitionExtension: ContentExtensionFor<"admonition"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    name: "admonition",
};
