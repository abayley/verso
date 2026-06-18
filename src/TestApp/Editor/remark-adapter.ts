import type { Nodes, Root, RootContent } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { blockFromMdast, collectRemarkPlugins } from "./content-extension.js";
import "./register-extensions.js";
import type { EditorBlock, EditorDocument } from "./editor-model.js";

/** Whether a document contains raw HTML (an `html` mdast node), via a plain parse independent of the
 * content-extension registry. Used to default a raw-HTML document to the lossless source mode. */
export function markdownHasRawHtml(markdown: string): boolean {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown) as Root;

    return nodeHasRawHtml(tree);
}

/** Whether an mdast node or any descendant is a raw `html` node. */
function nodeHasRawHtml(node: Nodes): boolean {
    if (node.type === "html") {
        return true;
    }

    return "children" in node && node.children.some((child: Nodes): boolean => nodeHasRawHtml(child));
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
