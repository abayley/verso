import { MarkdownEditorElement } from "./markdown-editor-element.js";

if (!customElements.get("markdown-editor")) {
    customElements.define("markdown-editor", MarkdownEditorElement);
}
