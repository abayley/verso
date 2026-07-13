import type { NodeViewRendererProps } from "@tiptap/core";
import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import { CODE_BLOCK_LANGUAGES, fenceLowlight } from "./fence-grammars.js";
import { CodeBlockView } from "./tiptap-code-block-view.js";

/**
 * The fenced-code-block node (RFC-0033): highlight.js highlighting via lowlight over the curated grammars
 * (see fence-grammars.ts), replacing StarterKit's plain `codeBlock`. Keeps the standard code-block schema (a
 * `language` attribute and a text body) and the `codeBlock` node name, so existing insert commands and the
 * DOM serialiser (`codeBlockFromElement`, which reads `textContent` and the `language-` class) are
 * unaffected. The NodeView adds the language picker (edit view) / language label (read view) on top of the
 * highlighted content.
 */
export const CodeBlock = CodeBlockLowlight.extend({
    addNodeView() {
        return (props: NodeViewRendererProps): CodeBlockView =>
            new CodeBlockView(props.node, props.editor, props.getPos, CODE_BLOCK_LANGUAGES);
    },
}).configure({ lowlight: fenceLowlight });
