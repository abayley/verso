import { Node } from "@tiptap/core";

/** Reads the footnote id attribute from a rendered footnote element. */
function idAttribute(element: HTMLElement): string {
    return element.getAttribute("data-footnote-id") ?? "";
}

/**
 * The editor-side inline footnote reference: an atom superscript carrying the footnote id, matching the
 * `sup.markdown-footnote-ref` markup the render and serialise seams use. It shows the id (numbering is a
 * document-level render concern, ADR-0040 validation only, not the editor surface).
 */
export const FootnoteReference = Node.create({
    name: "footnoteReference",
    inline: true,
    group: "inline",
    atom: true,
    selectable: true,

    addAttributes() {
        return {
            footnoteId: {
                default: "",
                parseHTML: (element: HTMLElement): string => idAttribute(element),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-footnote-id": String(attributes["footnoteId"] ?? ""),
                }),
            },
        };
    },

    parseHTML() {
        return [{ tag: "sup.markdown-footnote-ref" }];
    },

    renderHTML({ node }) {
        const id = String(node.attrs["footnoteId"] ?? "");

        return ["sup", { class: "markdown-footnote-ref", "data-footnote-id": id }, id];
    },
});

/**
 * The editor-side footnote definition: a block carrying the footnote id, with a non-editable `[^id]:`
 * label and an editable body, matching the `div.markdown-footnote-def` markup the serialise seam reads.
 */
export const FootnoteDefinition = Node.create({
    name: "footnoteDefinition",
    group: "block",
    content: "block+",
    defining: true,

    addAttributes() {
        return {
            footnoteId: {
                default: "",
                parseHTML: (element: HTMLElement): string => idAttribute(element),
                renderHTML: (): Record<string, never> => ({}),
            },
        };
    },

    parseHTML() {
        return [{ tag: "div.markdown-footnote-def" }];
    },

    renderHTML({ node }) {
        const id = String(node.attrs["footnoteId"] ?? "");

        return [
            "div",
            { class: "markdown-footnote-def", "data-footnote-id": id },
            ["span", { class: "markdown-footnote-def-label", contenteditable: "false" }, `[^${id}]:`],
            ["div", { class: "markdown-footnote-def-body" }, 0],
        ];
    },
});
