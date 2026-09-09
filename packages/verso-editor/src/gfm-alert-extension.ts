import type { Blockquote, Paragraph, PhrasingContent, RootContent, Text } from "mdast";
import { CALLOUT_KINDS, type CalloutKind, calloutKindFromClassName, isCalloutKind } from "./callout.js";
import type {
    ContentExtensionFor,
    ExtensionBlockInput,
    FromElementContext,
    ParseContext,
    ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock } from "./editor-model.js";
import { quoteMarkdownLines } from "./markdown-quote.js";

export type GfmAlertKind = CalloutKind;

/** The extension-owned payload carried on a custom GFM alert block. */
interface GfmAlertData {
    kind: GfmAlertKind;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        "gfm-alert": { block: GfmAlertData };
    }
}

const MARKER_PATTERN = new RegExp(`^\\[!(${CALLOUT_KINDS.map((kind) => kind.toUpperCase()).join("|")})\\](?:\\n|$)`);

/** Matches a leading GFM alert marker (`[!NOTE]` on its own line), returning the kind and match length. */
export function matchAlertMarker(text: string): { kind: GfmAlertKind; length: number } | null {
    const match = MARKER_PATTERN.exec(text);
    const kind = match?.[1]?.toLowerCase();

    if (!match || !isCalloutKind(kind)) {
        return null;
    }

    return {
        kind,
        length: match[0].length,
    };
}

// Parse: a blockquote whose first line is a GFM alert marker becomes a custom GFM alert block.

/** Recognises a GFM alert blockquote and converts it to a custom GFM alert block, declining otherwise. */
function blockFromMdast(node: RootContent, ctx: ParseContext): ExtensionBlockInput<"gfm-alert"> | null {
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
function alertMarker(node: Blockquote): { kind: GfmAlertKind; length: number } | null {
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

// Serialise-in: a rendered callout element (the Tiptap node's DOM) becomes a custom GFM alert block.

/** Recognises a `.markdown-alert` element and rebuilds the custom GFM alert block, declining otherwise. */
function blockFromElement(element: Element, ctx: FromElementContext): ExtensionBlockInput<"gfm-alert"> | null {
    if (element.tagName !== "DIV" || !element.classList.contains("markdown-alert")) {
        return null;
    }

    const kind = calloutKindFromClassName(element.classList, "markdown-alert");

    if (!kind) {
        return null;
    }

    const body = element.querySelector(".markdown-alert-body");

    return {
        children: body ? ctx.documentFromElements(body.children).blocks : [],
        data: { kind },
    };
}

// Serialise-out: a custom GFM alert block becomes a GFM alert blockquote.

/** Serialises a custom GFM alert block back to GFM alert Markdown. */
function blockToMarkdown(data: GfmAlertData, children: EditorBlock[] | undefined, ctx: ToMarkdownContext): string {
    const { kind } = data;
    const body = ctx.documentToMarkdown({ blocks: children ?? [] });
    const markdown = body.length > 0 ? `[!${kind.toUpperCase()}]\n${body}` : `[!${kind.toUpperCase()}]`;

    return quoteMarkdownLines(markdown);
}

/** GFM alert blockquotes (`> [!NOTE]`) recognised and styled as callouts. */
export const gfmAlertExtension: ContentExtensionFor<"gfm-alert"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    name: "gfm-alert",
};
