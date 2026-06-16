import { renderBlock } from "./content-extension.js";
import type { EditorBlock, EditorDocument } from "./editor-model.js";
import { parseMarkdown } from "./markdown-parse.js";
import "./register-extensions.js";

/** Renders the supported Markdown subset to HTML. */
export function renderMarkdown(markdown: string): string {
    return renderEditorDocument(parseMarkdown(markdown));
}

/** Renders an editor document to HTML through the content-extension registry. */
function renderEditorDocument(document: EditorDocument): string {
    return document.blocks.map((block: EditorBlock): string => renderBlock(block)).join("");
}
