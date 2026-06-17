import { mergeAttributes, Node } from "@tiptap/core";

/** Reads a string attribute from a rendered element, defaulting to empty. */
function stringAttribute(element: HTMLElement, name: string): string {
    return element.getAttribute(name) ?? "";
}

/** The marked image token (`![text](href "title")`) handed to the Markdown parse seam. */
interface MarkedImageToken {
    href?: string;
    text?: string;
    title?: string | null;
}

/**
 * The editor-side image: an inline atom carrying `src`/`alt`/`title`, matching the `<img>` markup the
 * serialise seam reads. It renders as a real `<img>` so the image shows inline while round-tripping to its
 * `![alt](src "title")` form. The bytes are served sandboxed (RFC-0018); no raw HTML enters the document.
 */
export const Image = Node.create({
    name: "image",
    group: "inline",
    inline: true,
    atom: true,
    draggable: true,

    addAttributes() {
        return {
            src: {
                default: "",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "src"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    src: String(attributes["src"] ?? ""),
                }),
            },
            alt: {
                default: "",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "alt"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    alt: String(attributes["alt"] ?? ""),
                }),
            },
            title: {
                default: null,
                parseHTML: (element: HTMLElement): string | null => element.getAttribute("title"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> =>
                    typeof attributes["title"] === "string" ? { title: attributes["title"] } : {},
            },
        };
    },

    parseHTML() {
        return [{ tag: "img[src]" }];
    },

    renderHTML({ HTMLAttributes }) {
        return ["img", mergeAttributes(HTMLAttributes)];
    },

    /**
     * Maps the marked `image` token to an image node. marked tokenises `![]()` correctly (unlike the
     * non-standard syntaxes other extensions pre-extract), so a parse handler is all the visual editor
     * needs to load images; serialising back to Markdown goes through the DOM serialise seam.
     */
    parseMarkdown(token: MarkedImageToken): { attrs: Record<string, unknown>; type: string } {
        return {
            attrs: { alt: token.text ?? "", src: token.href ?? "", title: token.title ?? null },
            type: "image",
        };
    },
});
