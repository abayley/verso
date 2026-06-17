import { mergeAttributes, Node, type NodeViewRendererProps } from "@tiptap/core";
import type { Node as ProseMirrorNode } from "@tiptap/pm/model";

/** The smallest width (px) a drag-resize may shrink an image to. */
const MIN_IMAGE_WIDTH = 32;

/** Reads a string attribute from a rendered element, defaulting to empty. */
function stringAttribute(element: HTMLElement, name: string): string {
    return element.getAttribute(name) ?? "";
}

/** Parses a positive integer width attribute value, or null when absent/invalid. */
function widthAttribute(value: string | null): number | null {
    if (value === null || !/^\d+$/.test(value)) {
        return null;
    }

    const width = Number(value);

    return width > 0 ? width : null;
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
            width: {
                default: null,
                parseHTML: (element: HTMLElement): number | null => widthAttribute(element.getAttribute("width")),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> =>
                    typeof attributes["width"] === "number" ? { width: String(attributes["width"]) } : {},
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
     * A node view that renders the image inside a wrapper carrying a corner drag handle, so an image can be
     * resized by dragging. The handle updates the `<img>` width live during the drag and commits the final
     * width to the node's `width` attribute on release; the DOM serialise seam reads that `width` back into
     * the `{width=N}` Markdown attribute. The image is an atom (no editable content), so all DOM mutations
     * are ignored to keep ProseMirror from re-parsing the live resize.
     */
    addNodeView() {
        return ({ node, editor, getPos }: NodeViewRendererProps): { dom: HTMLElement } & Record<string, unknown> => {
            const dom = document.createElement("span");
            dom.className = "markdown-image";

            const image = document.createElement("img");
            const handle = document.createElement("span");
            handle.className = "markdown-image__resize-handle";
            handle.setAttribute("contenteditable", "false");
            dom.append(image, handle);

            let current: ProseMirrorNode = node;
            let resizing = false;
            let startX = 0;
            let startWidth = 0;

            const syncImage = (from: ProseMirrorNode): void => {
                image.setAttribute("src", String(from.attrs["src"] ?? ""));
                image.setAttribute("alt", String(from.attrs["alt"] ?? ""));
                const title = from.attrs["title"];
                title === null || title === undefined
                    ? image.removeAttribute("title")
                    : image.setAttribute("title", String(title));
                const width = from.attrs["width"];
                typeof width === "number" ? image.setAttribute("width", String(width)) : image.removeAttribute("width");
            };
            syncImage(current);

            const onMove = (event: PointerEvent): void => {
                if (!resizing) {
                    return;
                }

                const width = Math.max(MIN_IMAGE_WIDTH, Math.round(startWidth + (event.clientX - startX)));
                image.setAttribute("width", String(width));
            };

            const onUp = (): void => {
                if (!resizing) {
                    return;
                }

                resizing = false;
                document.removeEventListener("pointermove", onMove);
                document.removeEventListener("pointerup", onUp);

                const position = getPos();
                const width = widthAttribute(image.getAttribute("width"));

                if (position !== undefined) {
                    editor.view.dispatch(
                        editor.state.tr.setNodeMarkup(position, undefined, { ...current.attrs, width }),
                    );
                }
            };

            handle.addEventListener("pointerdown", (event: PointerEvent): void => {
                event.preventDefault();
                event.stopPropagation();
                resizing = true;
                startX = event.clientX;
                startWidth = image.getBoundingClientRect().width;
                document.addEventListener("pointermove", onMove);
                document.addEventListener("pointerup", onUp);
            });

            return {
                dom,
                ignoreMutation: (): boolean => true,
                update: (updated: ProseMirrorNode): boolean => {
                    if (updated.type.name !== "image") {
                        return false;
                    }

                    current = updated;

                    if (!resizing) {
                        syncImage(updated);
                    }

                    return true;
                },
                destroy: (): void => {
                    document.removeEventListener("pointermove", onMove);
                    document.removeEventListener("pointerup", onUp);
                },
            };
        };
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
