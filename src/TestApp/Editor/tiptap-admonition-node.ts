import { Node } from "@tiptap/core";
import { type AdmonitionKind, admonitionTitle, kindFromClassName } from "./admonition-extension.js";

/** Normalises an unknown attribute value to a supported admonition kind. */
function asKind(value: unknown): AdmonitionKind {
    return value === "tip" || value === "important" || value === "warning" || value === "caution" ? value : "note";
}

/**
 * The editor-side custom node that renders a GFM alert as a styled callout: a non-editable title bar
 * plus an editable body. The kind is carried in the `markdown-alert-<kind>` class (no DOM attribute),
 * matching the callout markup the render and serialise seams use.
 */
export const Admonition = Node.create({
    name: "admonition",
    group: "block",
    content: "block+",
    defining: true,

    addAttributes() {
        return {
            kind: {
                default: "note",
                parseHTML: (element: HTMLElement): AdmonitionKind => kindFromClassName(element.classList) ?? "note",
                renderHTML: (): Record<string, never> => ({}),
            },
        };
    },

    parseHTML() {
        return [{ tag: "div.markdown-alert" }];
    },

    renderHTML({ node }) {
        const kind = asKind(node.attrs["kind"]);

        return [
            "div",
            { class: `markdown-alert markdown-alert-${kind}` },
            ["p", { class: "markdown-alert-title", contenteditable: "false" }, admonitionTitle(kind)],
            ["div", { class: "markdown-alert-body" }, 0],
        ];
    },
});
