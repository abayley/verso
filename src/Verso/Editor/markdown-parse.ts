import type { EditorDocument } from "./editor-model.js";
import { commonContentPipeline } from "./register-extensions.js";
import { parseMarkdownWithRemark } from "./remark-adapter.js";

/** Parses Markdown in the supported editor subset into an editor document. */
export function parseMarkdown(markdown: string): EditorDocument {
    return parseMarkdownWithRemark(markdown, commonContentPipeline);
}
