import type { Root, RootContent } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import { blockFromMdast, collectRemarkPlugins } from "./content-extension.js";
import "./register-extensions.js";
import type { EditorBlock, EditorDocument } from "./editor-model.js";

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
