import type { PhrasingContent, RootContent } from "mdast";
import {
    type ContentExtension,
    type FromElementContext,
    type ParseContext,
    type RenderContext,
    registerExtension,
    type ToMarkdownContext,
} from "./content-extension.js";
import type { EditorBlock, EditorDocument, InlineNode } from "./editor-model.js";

/** The extension-owned payload carried on a custom footnote reference (inline) or definition (block). */
interface FootnoteData {
    footnoteId: string;
}

/**
 * Per-render footnote numbering, assigned by first-reference order. Set by {@link renderDocument} and
 * read by {@link renderInline}; rendering is synchronous and non-reentrant, so module state is safe.
 */
let numbering = new Map<string, number>();

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

// Render: a document with footnotes renders numbered superscript references plus a collected list.

/** Renders a footnote reference to a numbered superscript link, declining any other inline node. */
function renderInline(node: InlineNode, ctx: RenderContext): string | null {
    if (!isFootnoteReference(node)) {
        return null;
    }

    const id = ctx.escapeHtml(footnoteId(node.data));
    const number = numbering.get(footnoteId(node.data)) ?? 0;

    return `<sup class="markdown-footnote-ref" id="fnref-${id}"><a href="#fn-${id}">${number}</a></sup>`;
}

/** Footnote definitions render in the collected list (via renderDocument), not in place. */
function renderBlock(block: EditorBlock): string | null {
    return isFootnoteDefinition(block) ? "" : null;
}

/** Takes over document rendering when footnotes are present: numbered references + a collected list. */
function renderDocument(document: EditorDocument, ctx: RenderContext): string | null {
    const referenceOrder: string[] = [];
    collectReferenceIds(document.blocks, referenceOrder);

    const definitions = new Map<string, EditorBlock & { children?: EditorBlock[] }>();

    for (const block of document.blocks) {
        if (isFootnoteDefinition(block)) {
            definitions.set(footnoteId(block.data), block);
        }
    }

    if (referenceOrder.length === 0 && definitions.size === 0) {
        return null;
    }

    numbering = new Map<string, number>();

    for (const id of [...referenceOrder, ...definitions.keys()]) {
        if (!numbering.has(id)) {
            numbering.set(id, numbering.size + 1);
        }
    }

    const body = ctx.renderBlocks(
        document.blocks.filter((block: EditorBlock): boolean => !isFootnoteDefinition(block)),
    );
    const items = [...numbering.keys()]
        .filter((id: string): boolean => definitions.has(id))
        .map((id: string): string => {
            const definition = definitions.get(id);
            const safe = ctx.escapeHtml(id);
            const inner = ctx.renderBlocks(definition?.children ?? []);

            return `<li id="fn-${safe}">${inner}<a class="markdown-footnote-backref" href="#fnref-${safe}">↩</a></li>`;
        })
        .join("");

    numbering = new Map<string, number>();
    const section = items ? `<section class="markdown-footnotes"><ol>${items}</ol></section>` : "";

    return `${body}${section}`;
}

/** Collects footnote reference ids in document order (first-reference numbering). */
function collectReferenceIds(blocks: EditorBlock[], into: string[]): void {
    for (const block of blocks) {
        if (block.type === "heading" || block.type === "paragraph") {
            collectInlineReferenceIds(block.children, into);
        } else if (block.type === "list") {
            for (const item of block.items) {
                collectReferenceIds(item.blocks, into);
            }
        } else if (block.type === "blockquote") {
            collectReferenceIds(block.blocks, into);
        } else if (block.type === "custom" && block.children) {
            collectReferenceIds(block.children, into);
        }
    }
}

/** Collects footnote reference ids from inline nodes in order. */
function collectInlineReferenceIds(nodes: InlineNode[], into: string[]): void {
    for (const node of nodes) {
        if (isFootnoteReference(node)) {
            into.push(footnoteId(node.data));

            continue;
        }

        const children = (node as { children?: InlineNode[] }).children;

        if (children) {
            collectInlineReferenceIds(children, into);
        }
    }
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
    renderBlock,
    renderDocument,
    renderInline,
};

registerExtension(footnoteExtension);
