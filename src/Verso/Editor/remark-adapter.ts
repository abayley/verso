import type { Nodes, Root, RootContent } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { BADGE_ATTR } from "./badge-syntax.js";
import { blockFromMdast, type ContentPipeline, collectRemarkPlugins } from "./content-extension.js";
import "./register-extensions.js";
import type { EditorBlock, EditorDocument } from "./editor-model.js";

/** A raw `html` node's verbatim text, its source-offset span, and whether it is block-level. */
export interface RawHtmlSpan {
    value: string;
    start: number;
    end: number;
    block: boolean;
}

// The mdast parents that hold *inline* (phrasing) HTML; an `html` node anywhere else is block-level. A
// block raw-HTML node (e.g. an export comment on its own line) must not be merged into a neighbouring
// paragraph, so the visual editor models it as a block (RFC-0019 follow-up).
const INLINE_HTML_PARENTS = new Set(["paragraph", "heading", "tableCell"]);

/** The source spans of every raw `html` node, for pre-extracting raw HTML before the visual editor's
 * Markdown loader (marked) interprets or drops it. Offsets index the given Markdown string. */
export function rawHtmlSpans(markdown: string): RawHtmlSpan[] {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown) as Root;
    const spans: RawHtmlSpan[] = [];

    const visit = (node: Nodes, parentType: string): void => {
        const start = node.position?.start?.offset;
        const end = node.position?.end?.offset;

        if (node.type === "html" && start !== undefined && end !== undefined) {
            spans.push({ block: !INLINE_HTML_PARENTS.has(parentType), end, start, value: node.value });
        }

        if ("children" in node) {
            for (const child of node.children) {
                visit(child, node.type);
            }
        }
    };

    visit(tree, "root");

    return spans;
}

/** A badge lozenge's text, colour, and source-offset span (the code span plus its `{.badge.<colour>}`). */
export interface BadgeSpan {
    text: string;
    colour: string;
    start: number;
    end: number;
}

/** The source spans of every badge lozenge, for pre-extracting them before the visual editor's marked
 * loader splits the code span from its attribute list. Offsets index the given Markdown string. */
export function badgeSpans(markdown: string): BadgeSpan[] {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown) as Root;
    const spans: BadgeSpan[] = [];

    const visit = (node: Nodes): void => {
        if (!("children" in node)) {
            return;
        }

        const children = node.children;

        for (let index = 0; index < children.length; index += 1) {
            const code = children[index];
            const next = children[index + 1];

            if (code?.type !== "inlineCode" || next?.type !== "text") {
                continue;
            }

            const match = BADGE_ATTR.exec(next.value);
            const start = code.position?.start?.offset;
            const attrStart = next.position?.start?.offset;

            if (match && start !== undefined && attrStart !== undefined) {
                spans.push({ colour: match[1] ?? "", end: attrStart + match[0].length, start, text: code.value });
            }
        }

        for (const child of children) {
            visit(child);
        }
    };

    visit(tree);

    return spans;
}

/** Parses Markdown with remark and converts the mdast tree through the content-extension registry. */
export function parseMarkdownWithRemark(markdown: string, pipeline?: ContentPipeline): EditorDocument {
    // Extensions may install syntax plugins (e.g. collapsibles), so run the processor's transformers
    // (runSync) after parsing rather than using parse() alone.
    const processor = unified()
        .use(remarkParse)
        .use(remarkGfm)
        .use(pipeline?.remarkPlugins ?? collectRemarkPlugins());
    const tree = processor.runSync(processor.parse(markdown)) as Root;

    if (pipeline) {
        return pipeline.documentFromMdast(tree.children);
    }

    return { blocks: tree.children.map((node: RootContent): EditorBlock => blockFromMdast(node)) };
}
