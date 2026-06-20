import { Mark, mergeAttributes } from "@tiptap/core";
import { badgeStyle, COLOUR_TOKEN } from "./badge-syntax.js";

/**
 * The editor-side badge (document-tree mode, RFC-0021): a mark over editable text carrying a `colour`,
 * matching the `span.badge` markup the serialise seam reads. It renders a coloured pill -- the validated
 * colour as an inline background -- so a badge round-trips to `` `text`{.badge.<colour>} ``. The mark
 * excludes other inline marks: a badge's content is a code span, so it cannot carry bold/italic/link.
 */
export const Badge = Mark.create({
    name: "badge",
    excludes: "_",

    addAttributes() {
        return {
            colour: {
                default: "",
                parseHTML: (element: HTMLElement): string => element.getAttribute("data-badge-colour") ?? "",
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-badge-colour": String(attributes["colour"] ?? ""),
                }),
            },
        };
    },

    parseHTML() {
        return [{ tag: "span.badge" }];
    },

    renderHTML({ mark, HTMLAttributes }) {
        const colour = String(mark.attrs["colour"] ?? "");
        const style = COLOUR_TOKEN.test(colour) ? { style: badgeStyle(colour) } : {};

        return ["span", mergeAttributes(HTMLAttributes, { class: "badge" }, style), 0];
    },
});
