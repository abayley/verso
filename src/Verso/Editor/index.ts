import { MarkdownEditorElement } from "./markdown-editor-element.js";
import { installTooltips } from "./toolbar-tooltip-controller.js";
import { installTrashRestore } from "./trash-page.js";

if (!customElements.get("markdown-editor")) {
    customElements.define("markdown-editor", MarkdownEditorElement);
}

// The delegated data-tooltip handler works on every page that loads the bundle
// (editor, reader, and the version pages), so it is installed at module load.
installTooltips();
// The trash page's Restore buttons (a no-op elsewhere; the bundle loads on every version page).
installTrashRestore();
