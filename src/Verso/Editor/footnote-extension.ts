import type { PhrasingContent, RootContent } from "mdast";
import {
    type ContentExtension,
    type FromElementContext,
    type ParseContext,
    registerExtension,
    type ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock, InlineNode } from "./editor-model.js";

/** The extension-owned payload carried on a custom footnote reference (inline) or definition (block). */
interface FootnoteData {
    footnoteId: string;
}

/** Whether an editor block is a footnote definition. */
function isFootnoteDefinition(
    block: EditorBlock,
): block is EditorBlock & { extension: string; data: unknown; children?: EditorBlock[] } {
    return block.type === "custom" && block.extension === "footnote";
}

/** Whether an editor inline node is a footnote reference. */
function isFootnoteReference(node: InlineNode): node is InlineNode & { extension: string; data: unknown } {
    return node.type === "custom" && node.extension === "footnote";
}

/** Reads the footnote id from a custom footnote node's payload. */
function footnoteId(data: unknown): string {
    return (data as FootnoteData).footnoteId;
}

// Parse: footnoteReference -> custom inline; footnoteDefinition -> custom block.

/** Converts an mdast footnote reference to a custom footnote inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent): InlineNode | null {
    if (node.type !== "footnoteReference") {
        return null;
    }

    return { data: { footnoteId: node.label ?? node.identifier }, extension: "footnote", type: "custom" };
}

/** Converts an mdast footnote definition to a custom footnote block, declining any other node. */
function blockFromMdast(node: RootContent, ctx: ParseContext): EditorBlock | null {
    if (node.type !== "footnoteDefinition") {
        return null;
    }

    return {
        children: ctx.blocksFromMdast(node.children),
        data: { footnoteId: node.label ?? node.identifier },
        extension: "footnote",
        type: "custom",
    };
}

// Serialise-in: a reference superscript -> custom inline; a definition element -> custom block.

/** Recognises a footnote reference superscript and rebuilds the custom inline node, declining otherwise. */
function inlineFromElement(node: ChildNode): InlineNode[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (element.tagName !== "SUP" || !element.classList.contains("markdown-footnote-ref")) {
        return null;
    }

    const id = element.getAttribute("data-footnote-id");

    if (id === null) {
        return null;
    }

    return [{ data: { footnoteId: id }, extension: "footnote", type: "custom" }];
}

/** Recognises a footnote definition element and rebuilds the custom block, declining otherwise. */
function blockFromElement(element: Element, ctx: FromElementContext): EditorBlock | null {
    if (element.tagName !== "DIV" || !element.classList.contains("markdown-footnote-def")) {
        return null;
    }

    const id = element.getAttribute("data-footnote-id");

    if (id === null) {
        return null;
    }

    const body = element.querySelector(".markdown-footnote-def-body");

    return {
        children: body ? ctx.documentFromElements(body.children).blocks : [],
        data: { footnoteId: id },
        extension: "footnote",
        type: "custom",
    };
}

// Serialise-out: a reference -> [^id]; a definition -> [^id]: body (continuations indented four spaces).

/** Serialises a footnote reference to a `[^id]` label, declining any other inline node. */
function inlineToMarkdown(node: InlineNode): string | null {
    if (!isFootnoteReference(node)) {
        return null;
    }

    return `[^${footnoteId(node.data)}]`;
}

/** Serialises a footnote definition to `[^id]: body` Markdown, declining any other block. */
function blockToMarkdown(block: EditorBlock, ctx: ToMarkdownContext): string | null {
    if (!isFootnoteDefinition(block)) {
        return null;
    }

    const body = ctx.documentToMarkdown({ blocks: block.children ?? [] });
    const [firstLine, ...rest] = body.split("\n");
    const head = `[^${footnoteId(block.data)}]: ${firstLine ?? ""}`;
    const indented = rest.map((line: string): string => (line.length > 0 ? `    ${line}` : "")).join("\n");

    return rest.length > 0 ? `${head}\n${indented}` : head;
}

/** GFM footnotes (`[^id]` references and `[^id]:` definitions), rendered as a collected numbered list. */
const footnoteExtension: ContentExtension = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "footnote",
};

registerExtension(footnoteExtension);
