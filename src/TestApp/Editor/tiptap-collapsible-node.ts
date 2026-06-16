import { Node } from "@tiptap/core";
import type { Node as ProseMirrorNode } from "@tiptap/pm/model";
import {
    COLLAPSIBLE_KINDS,
    type CollapsibleKind,
    collapsibleTitle,
    kindFromClassName,
} from "./collapsible-extension.js";

/** Normalises an unknown attribute value to a supported collapsible type. */
function asKind(value: unknown): CollapsibleKind {
    return COLLAPSIBLE_KINDS.includes(value as CollapsibleKind) ? (value as CollapsibleKind) : "note";
}

/** The title shown on a collapsible's bar: its explicit title, else the type label. */
function barTitle(node: ProseMirrorNode): string {
    const title = node.attrs["title"];

    return typeof title === "string" ? title : collapsibleTitle(asKind(node.attrs["collapsibleType"]));
}

/**
 * The editor-side custom node that renders a mkdocs collapsible as a styled callout: a non-editable
 * title bar that toggles the open state on click, plus an editable body. The type, title, and open
 * state are carried in the callout's class and `data-*` attributes, matching the markup the render and
 * serialise seams use.
 */
export const Collapsible = Node.create({
    name: "collapsible",
    group: "block",
    content: "block+",
    defining: true,

    addAttributes() {
        return {
            collapsibleType: {
                default: "note",
                parseHTML: (element: HTMLElement): CollapsibleKind => kindFromClassName(element.classList) ?? "note",
                renderHTML: (): Record<string, never> => ({}),
            },
            title: {
                default: null,
                parseHTML: (element: HTMLElement): string | null => element.getAttribute("data-title"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> =>
                    typeof attributes["title"] === "string" ? { "data-title": attributes["title"] } : {},
            },
            open: {
                default: false,
                parseHTML: (element: HTMLElement): boolean => element.getAttribute("data-open") === "true",
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> => ({
                    "data-open": String(Boolean(attributes["open"])),
                }),
            },
        };
    },

    parseHTML() {
        return [{ tag: "div.markdown-collapsible" }];
    },

    renderHTML({ node }) {
        const kind = asKind(node.attrs["collapsibleType"]);

        return [
            "div",
            { class: `markdown-collapsible markdown-collapsible-${kind}` },
            ["p", { class: "markdown-collapsible-title", contenteditable: "false" }, barTitle(node)],
            ["div", { class: "markdown-collapsible-body" }, 0],
        ];
    },

    addNodeView() {
        return ({ node, editor, getPos }) => {
            const dom = document.createElement("div");
            const titleBar = document.createElement("p");
            titleBar.className = "markdown-collapsible-title";
            titleBar.contentEditable = "false";
            const body = document.createElement("div");
            body.className = "markdown-collapsible-body";
            dom.append(titleBar, body);

            const reflect = (current: ProseMirrorNode): void => {
                const kind = asKind(current.attrs["collapsibleType"]);
                dom.className = `markdown-collapsible markdown-collapsible-${kind}`;
                dom.dataset["open"] = String(Boolean(current.attrs["open"]));

                if (typeof current.attrs["title"] === "string") {
                    dom.dataset["title"] = current.attrs["title"];
                } else {
                    delete dom.dataset["title"];
                }

                titleBar.textContent = barTitle(current);
            };

            titleBar.addEventListener("mousedown", (event: MouseEvent): void => event.preventDefault());
            titleBar.addEventListener("click", (): void => {
                const position = getPos();

                if (typeof position !== "number") {
                    return;
                }

                const current = editor.state.doc.nodeAt(position);
                editor
                    .chain()
                    .command(({ tr }): boolean => {
                        tr.setNodeAttribute(position, "open", !current?.attrs["open"]);

                        return true;
                    })
                    .run();
            });

            reflect(node);

            return {
                dom,
                contentDOM: body,
                update: (updated: ProseMirrorNode): boolean => {
                    if (updated.type.name !== "collapsible") {
                        return false;
                    }

                    reflect(updated);

                    return true;
                },
            };
        };
    },
});
