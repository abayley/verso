import { Node } from "@tiptap/core";
import { calloutKindFromClassName, calloutTitle, isCalloutKind } from "./callout.js";
import type { GfmAlertKind } from "./gfm-alert-extension.js";

/** Normalises an unknown attribute value to a supported GFM alert kind. */
function asKind(value: unknown): GfmAlertKind {
    return isCalloutKind(value) ? value : "note";
}

/**
 * The editor-side custom node that renders a GFM alert as a styled callout: a non-editable title bar
 * plus an editable body. The kind is carried in the `markdown-alert-<kind>` class (no DOM attribute),
 * matching the callout markup the render and serialise seams use.
 */
export const GfmAlert = Node.create({
    name: "gfmAlert",
    group: "block",
    content: "block+",
    defining: true,

    addAttributes() {
        return {
            kind: {
                default: "note",
                parseHTML: (element: HTMLElement): GfmAlertKind =>
                    calloutKindFromClassName(element.classList, "markdown-alert") ?? "note",
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
            ["p", { class: "markdown-alert-title", contenteditable: "false" }, calloutTitle(kind)],
            ["div", { class: "markdown-alert-body" }, 0],
        ];
    },
});
