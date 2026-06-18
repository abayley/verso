import type { Nodes, Root, RootContent } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { blockFromMdast, collectRemarkPlugins } from "./content-extension.js";
import "./register-extensions.js";
import type { EditorBlock, EditorDocument } from "./editor-model.js";

/** A raw `html` node's verbatim text and its source-offset span in the Markdown. */
export interface RawHtmlSpan {
    value: string;
    start: number;
    end: number;
}

/** The source spans of every raw `html` node, for pre-extracting raw HTML before the visual editor's
 * Markdown loader (marked) interprets or drops it. Offsets index the given Markdown string. */
export function rawHtmlSpans(markdown: string): RawHtmlSpan[] {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown) as Root;
    const spans: RawHtmlSpan[] = [];

    const visit = (node: Nodes): void => {
        const start = node.position?.start?.offset;
        const end = node.position?.end?.offset;

        if (node.type === "html" && start !== undefined && end !== undefined) {
            spans.push({ end, start, value: node.value });
        }

        if ("children" in node) {
            for (const child of node.children) {
                visit(child);
            }
        }
    };

    visit(tree);

    return spans;
}

/** Parses Markdown with remark and converts the mdast tree through the content-extension registry. */
export function parseMarkdownWithRemark(markdown: string): EditorDocument {
    // Extensions may install syntax plugins (e.g. collapsibles), so run the processor's transformers
    // (runSync) after parsing rather than using parse() alone.
    const processor = unified().use(remarkParse).use(remarkGfm).use(collectRemarkPlugins());
    const tree = processor.runSync(processor.parse(markdown)) as Root;

    return {
        blocks: tree.children.map((node: RootContent): EditorBlock => blockFromMdast(node)),
    };
}
