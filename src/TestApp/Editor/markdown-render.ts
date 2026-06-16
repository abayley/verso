import { renderDocument } from "./content-extension.js";
import { parseMarkdown } from "./markdown-parse.js";
import "./register-extensions.js";

/** Renders the supported Markdown subset to HTML. */
export function renderMarkdown(markdown: string): string {
    return renderDocument(parseMarkdown(markdown));
}
