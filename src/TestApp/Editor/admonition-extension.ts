import type { Blockquote, Paragraph, PhrasingContent, RootContent, Text } from "mdast";
import {
    type ContentExtension,
    type ParseContext,
    type RenderContext,
    registerExtension,
    type ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock } from "./editor-model.js";

/** The GFM alert kinds recognised as admonitions. */
const ADMONITION_KINDS = ["note", "tip", "important", "warning", "caution"] as const;

type AdmonitionKind = (typeof ADMONITION_KINDS)[number];

/** The extension-owned payload carried on a custom admonition block. */
interface AdmonitionData {
    kind: AdmonitionKind;
}

const MARKER_PATTERN = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\n|$)/;

/** Title-cases an admonition kind for the rendered callout heading. */
function admonitionTitle(kind: AdmonitionKind): string {
    return kind.charAt(0).toUpperCase() + kind.slice(1);
}

// Parse: a blockquote whose first line is a GFM alert marker becomes a custom admonition block.

/** Recognises a GFM alert blockquote and converts it to a custom admonition block, declining otherwise. */
function blockFromMdast(node: RootContent, ctx: ParseContext): EditorBlock | null {
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
        extension: "admonition",
        type: "custom",
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

    const match = MARKER_PATTERN.exec(firstInline.value);
    const kind = match?.[1]?.toLowerCase();

    if (!match || !kind) {
        return null;
    }

    return {
        kind: kind as AdmonitionKind,
        length: match[0].length,
    };
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

// Render: a custom admonition block becomes a callout with a title bar and the body blocks.

/** Renders a custom admonition block to callout HTML, declining any other block. */
function renderBlock(block: EditorBlock, ctx: RenderContext): string | null {
    if (block.type !== "custom" || block.extension !== "admonition") {
        return null;
    }

    const { kind } = block.data as AdmonitionData;
    const title = ctx.escapeHtml(admonitionTitle(kind));
    const body = ctx.renderBlocks(block.children ?? []);

    return `<div class="markdown-alert markdown-alert-${kind}"><p class="markdown-alert-title">${title}</p>${body}</div>`;
}

// Serialise-out: a custom admonition block becomes a GFM alert blockquote.

/** Serialises a custom admonition block back to GFM alert Markdown, declining any other block. */
function blockToMarkdown(block: EditorBlock, ctx: ToMarkdownContext): string | null {
    if (block.type !== "custom" || block.extension !== "admonition") {
        return null;
    }

    const { kind } = block.data as AdmonitionData;
    const body = ctx.documentToMarkdown({ blocks: block.children ?? [] });
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
const admonitionExtension: ContentExtension = {
    blockFromMdast,
    blockToMarkdown,
    name: "admonition",
    renderBlock,
};

registerExtension(admonitionExtension);
