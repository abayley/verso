import type { PhrasingContent, RootContent } from "mdast";
import type {
    ContentExtensionFor,
    ExtensionBlockInput,
    ExtensionInlineInput,
    FromElementContext,
    ParseContext,
    ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock } from "./editor-model.js";

/** The extension-owned payload carried on a custom footnote reference (inline) or definition (block). */
interface FootnoteData {
    footnoteId: string;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        footnote: { block: FootnoteData; inline: FootnoteData };
    }
}

// Parse: footnoteReference -> custom inline; footnoteDefinition -> custom block.

/** Converts an mdast footnote reference to a custom footnote inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent): ExtensionInlineInput<"footnote"> | null {
    if (node.type !== "footnoteReference") {
        return null;
    }

    return { data: { footnoteId: node.label ?? node.identifier } };
}

/** Converts an mdast footnote definition to a custom footnote block, declining any other node. */
function blockFromMdast(node: RootContent, ctx: ParseContext): ExtensionBlockInput<"footnote"> | null {
    if (node.type !== "footnoteDefinition") {
        return null;
    }

    return {
        children: ctx.blocksFromMdast(node.children),
        data: { footnoteId: node.label ?? node.identifier },
    };
}

// Serialise-in: a reference superscript -> custom inline; a definition element -> custom block.

/** Recognises a footnote reference superscript and rebuilds the custom inline node, declining otherwise. */
function inlineFromElement(node: ChildNode): ExtensionInlineInput<"footnote">[] | null {
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

    return [{ data: { footnoteId: id } }];
}

/** Recognises a footnote definition element and rebuilds the custom block, declining otherwise. */
function blockFromElement(element: Element, ctx: FromElementContext): ExtensionBlockInput<"footnote"> | null {
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
    };
}

// Serialise-out: a reference -> [^id]; a definition -> [^id]: body (continuations indented four spaces).

/** Serialises a footnote reference to a `[^id]` label, declining any other inline node. */
function inlineToMarkdown(data: FootnoteData): string {
    return `[^${data.footnoteId}]`;
}

/** Serialises a footnote definition to `[^id]: body` Markdown, declining any other block. */
function blockToMarkdown(data: FootnoteData, children: EditorBlock[] | undefined, ctx: ToMarkdownContext): string {
    const body = ctx.documentToMarkdown({ blocks: children ?? [] });
    const [firstLine, ...rest] = body.split("\n");
    const head = `[^${data.footnoteId}]: ${firstLine ?? ""}`;
    const indented = rest.map((line: string): string => (line.length > 0 ? `    ${line}` : "")).join("\n");

    return rest.length > 0 ? `${head}\n${indented}` : head;
}

/** GFM footnotes (`[^id]` references and `[^id]:` definitions), rendered as a collected numbered list. */
export const footnoteExtension: ContentExtensionFor<"footnote"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "footnote",
};
