import { mergeAttributes, Node } from "@tiptap/core";
import { isHtmlComment } from "./raw-html-extension.js";

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
        const html = String(node.attrs["html"] ?? "");

        return ["span", mergeAttributes({ class: rawHtmlClassName(html), contenteditable: "false" }), html];
    },
});

/**
 * The block-level counterpart of {@link RawHtml}: a block atom carrying verbatim HTML, matching the
 * `div.markdown-raw-html` markup the serialise seam reads as a block. Block raw HTML (an export comment on
 * its own line, an MkDocs grid-card `<div>`) is modelled as a block so it stays on its own line through the
 * round-trip rather than being merged into a neighbouring paragraph (RFC-0019 follow-up). Comments render
 * hidden; other block HTML renders inert-but-visible.
 */
export const RawHtmlBlock = Node.create({
    name: "rawHtmlBlock",
    group: "block",
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
        return [{ tag: "div.markdown-raw-html" }];
    },

    renderHTML({ node }) {
        const html = String(node.attrs["html"] ?? "");

        return ["div", mergeAttributes({ class: rawHtmlClassName(html), contenteditable: "false" }), html];
    },
});

/** The placeholder class for raw HTML: comments get the hidden modifier, other HTML stays inert-visible. */
function rawHtmlClassName(html: string): string {
    return isHtmlComment(html) ? "markdown-raw-html markdown-raw-html--comment" : "markdown-raw-html";
}
