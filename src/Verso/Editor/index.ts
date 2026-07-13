import { MarkdownEditorElement } from "./markdown-editor-element.js";
import { installTooltips } from "./toolbar-tooltip-controller.js";
import { installTrashPurge, installTrashRestore } from "./trash-page.js";
import { installUndoApply } from "./undo-page.js";

if (!customElements.get("markdown-editor")) {
    customElements.define("markdown-editor", MarkdownEditorElement);
}

// The delegated data-tooltip handler works on every page that loads the bundle
// (editor, reader, and the version pages), so it is installed at module load.
installTooltips();
// The trash page's Restore, Delete forever, and Empty trash buttons (no-ops elsewhere;
// the bundle loads on every version page).
installTrashRestore();
installTrashPurge();
// The undo page's Undo buttons (likewise a delegated no-op elsewhere).
installUndoApply();
