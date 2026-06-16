import type { RootContent } from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import "./base-extension.js";
import { blockFromMdast } from "./content-extension.js";
import type { EditorBlock, EditorDocument } from "./editor-model.js";

/** Parses Markdown with remark and converts the mdast tree through the content-extension registry. */
export function parseMarkdownWithRemark(markdown: string): EditorDocument {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown);

    return {
        blocks: tree.children.map((node: RootContent): EditorBlock => blockFromMdast(node)),
    };
}
