import { mergeAttributes, Node } from "@tiptap/core";

/**
 * The editor-side raw-HTML node (document-tree mode): an inline atom carrying a verbatim HTML string,
 * matching the `span.markdown-raw-html` markup the serialise seam reads. It renders the HTML inert -- as
 * the span's text content, shown escaped, never as live HTML -- so a document's raw HTML (export-metadata
 * comments, occasional markup) survives a visual-editor round-trip without being interpreted or executed.
 * The verbatim HTML is the element's text content (not an attribute), which the DOM serialise seam reads.
 */
export const RawHtml = Node.create({
    name: "rawHtml",
    group: "inline",
    inline: true,
    atom: true,
    selectable: true,

    addAttributes() {
        return {
            html: {
                default: "",
                parseHTML: (element: HTMLElement): string => element.textContent ?? "",
                renderHTML: (): Record<string, string> => ({}),
            },
        };
    },

    parseHTML() {
        return [{ tag: "span.markdown-raw-html" }];
    },

    renderHTML({ node }) {
        return [
            "span",
            mergeAttributes({ class: "markdown-raw-html", contenteditable: "false" }),
            String(node.attrs["html"] ?? ""),
        ];
    },
});
