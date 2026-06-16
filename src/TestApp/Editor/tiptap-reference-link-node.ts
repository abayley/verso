import { Mark, mergeAttributes, Node } from "@tiptap/core";

/** Reads a string attribute from a rendered element, defaulting to empty. */
function stringAttribute(element: HTMLElement, name: string): string {
    return element.getAttribute(name) ?? "";
}

/**
 * The editor-side reference link: a mark over the link text carrying the reference label, form, and the
 * resolved destination, matching the `a.markdown-reference-link` markup the serialise seam reads. It
 * renders as a real anchor so the reference shows as a link while round-tripping to its `[text][id]` form.
 */
export const ReferenceLink = Mark.create({
    name: "referenceLink",
    inclusive: false,

    addAttributes() {
        return {
            label: {
                default: "",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "data-reference-label"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-reference-label": String(attributes["label"] ?? ""),
                }),
            },
            referenceType: {
                default: "full",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "data-reference-type") || "full",
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-reference-type": String(attributes["referenceType"] ?? "full"),
                }),
            },
            url: {
                default: "",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "href"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    href: String(attributes["url"] ?? ""),
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
        return [{ tag: "a.markdown-reference-link" }];
    },

    renderHTML({ HTMLAttributes }) {
        return ["a", mergeAttributes(HTMLAttributes, { class: "markdown-reference-link" }), 0];
    },
});

/**
 * The editor-side reference link definition: an atom block carrying the label, destination, and title,
 * matching the `div.markdown-reference-def` markup the serialise seam reads. It shows the `[id]: url`
 * source as non-editable chrome (definitions are invisible markup, but kept visible here so they survive).
 */
export const ReferenceDefinition = Node.create({
    name: "referenceDefinition",
    group: "block",
    atom: true,
    selectable: true,

    addAttributes() {
        return {
            label: {
                default: "",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "data-reference-label"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-reference-label": String(attributes["label"] ?? ""),
                }),
            },
            url: {
                default: "",
                parseHTML: (element: HTMLElement): string => stringAttribute(element, "data-reference-url"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-reference-url": String(attributes["url"] ?? ""),
                }),
            },
            title: {
                default: null,
                parseHTML: (element: HTMLElement): string | null => element.getAttribute("data-reference-title"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> =>
                    typeof attributes["title"] === "string" ? { "data-reference-title": attributes["title"] } : {},
            },
        };
    },

    parseHTML() {
        return [{ tag: "div.markdown-reference-def" }];
    },

    renderHTML({ node, HTMLAttributes }) {
        const label = String(node.attrs["label"] ?? "");
        const url = String(node.attrs["url"] ?? "");
        const title = typeof node.attrs["title"] === "string" ? node.attrs["title"] : null;
        const source = title !== null ? `[${label}]: ${url} "${title}"` : `[${label}]: ${url}`;

        return [
            "div",
            mergeAttributes(HTMLAttributes, { class: "markdown-reference-def", contenteditable: "false" }),
            source,
        ];
    },
});
