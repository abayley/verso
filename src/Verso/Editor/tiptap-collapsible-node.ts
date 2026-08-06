import { mergeAttributes, Node as TiptapNode } from "@tiptap/core";
import type { Node as ProseMirrorNode } from "@tiptap/pm/model";
import { calloutKindFromClassName, calloutTitle, isCalloutKind } from "./callout.js";
import type { CollapsibleKind } from "./collapsible-extension.js";

/** Normalises an unknown attribute value to a supported collapsible type. */
function asKind(value: unknown): CollapsibleKind {
    return isCalloutKind(value) ? value : "note";
}

/** The title shown on a collapsible's bar: its explicit title, else the type label. */
function barTitle(node: ProseMirrorNode): string {
    const title = node.attrs["title"];

    return typeof title === "string" ? title : calloutTitle(asKind(node.attrs["collapsibleType"]));
}

/**
 * The editor-side custom node that renders a mkdocs collapsible as a styled callout: a non-editable
 * title bar that toggles the open state on click, plus an editable body. The type, title, and open
 * state are carried in the callout's class and `data-*` attributes, matching the markup the render and
 * serialise seams use.
 */
export const Collapsible = TiptapNode.create({
    name: "collapsible",
    group: "block",
    content: "block+",
    defining: true,

    addAttributes() {
        return {
            collapsibleType: {
                default: "note",
                parseHTML: (element: HTMLElement): CollapsibleKind =>
                    calloutKindFromClassName(element.classList, "markdown-collapsible") ?? "note",
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
                // Native <details open>: the boolean attribute is the open state.
                parseHTML: (element: HTMLElement): boolean => element.hasAttribute("open"),
                renderHTML: (attributes: Record<string, unknown>): Record<string, string> =>
                    attributes["open"] ? { open: "" } : {},
            },
        };
    },

    parseHTML() {
        return [{ tag: "details.markdown-collapsible" }];
    },

    renderHTML({ node, HTMLAttributes }) {
        const kind = asKind(node.attrs["collapsibleType"]);

        return [
            "details",
            mergeAttributes(HTMLAttributes, { class: `markdown-collapsible markdown-collapsible-${kind}` }),
            [
                "summary",
                { class: "markdown-collapsible-title", contenteditable: "false" },
                ["span", { class: "markdown-collapsible-title-text" }, barTitle(node)],
            ],
            ["div", { class: "markdown-collapsible-body" }, 0],
        ];
    },

    addNodeView() {
        return ({ node, editor, getPos }) => {
            const dom = document.createElement("details");
            const titleBar = document.createElement("summary");
            titleBar.className = "markdown-collapsible-title";
            titleBar.contentEditable = "false";
            // The title is an editable span; the rest of the summary (the disclosure arrow and padding) is
            // the toggle. So clicking the title text edits it, while clicking elsewhere toggles open/closed.
            const titleText = document.createElement("span");
            titleText.className = "markdown-collapsible-title-text";
            titleText.contentEditable = "true";
            titleBar.append(titleText);
            const body = document.createElement("div");
            body.className = "markdown-collapsible-body";
            dom.append(titleBar, body);

            let editingTitle = false;

            const reflect = (current: ProseMirrorNode): void => {
                const kind = asKind(current.attrs["collapsibleType"]);
                dom.className = `markdown-collapsible markdown-collapsible-${kind}`;
                // The open state lives in the document model (round-trips to ??? / ???+, undoable); drive the
                // native <details open> from it rather than letting the browser toggle it directly (ADR-054).
                dom.open = Boolean(current.attrs["open"]);

                if (typeof current.attrs["title"] === "string") {
                    dom.dataset["title"] = current.attrs["title"];
                } else {
                    delete dom.dataset["title"];
                }

                // Don't rewrite the title text while the user is editing it (it would reset the caret).
                if (!editingTitle) {
                    const label = barTitle(current);

                    if (titleText.textContent !== label) {
                        titleText.textContent = label;
                    }
                }
            };

            const currentNode = (): ProseMirrorNode | null => {
                const position = getPos();

                return typeof position === "number" ? editor.state.doc.nodeAt(position) : null;
            };

            const setNodeAttr = (name: "open" | "title", value: unknown): void => {
                const position = getPos();

                if (typeof position === "number") {
                    editor
                        .chain()
                        .command(({ tr }): boolean => {
                            tr.setNodeAttribute(position, name, value);

                            return true;
                        })
                        .run();
                }
            };

            // Toggle area (everything but the editable title): suppress the native <details> toggle and the
            // PM focus/selection steal, and drive open from the model.
            titleBar.addEventListener("mousedown", (event: MouseEvent): void => {
                if (!titleText.contains(event.target as Node)) {
                    event.preventDefault();
                }
            });
            titleBar.addEventListener("click", (event: MouseEvent): void => {
                event.preventDefault();

                if (!titleText.contains(event.target as Node)) {
                    setNodeAttr("open", !currentNode()?.attrs["open"]);
                }
            });

            // Title editing: keep the model in sync per keystroke (so a save mid-edit is correct), treating an
            // empty title as no title. Titles are single line, so Enter commits (blurs) rather than wrapping.
            titleText.addEventListener("focus", (): void => {
                editingTitle = true;
            });
            titleText.addEventListener("blur", (): void => {
                editingTitle = false;
                const current = currentNode();

                if (current) {
                    reflect(current);
                }
            });
            titleText.addEventListener("input", (): void => {
                const text = titleText.textContent ?? "";
                setNodeAttr("title", text === "" ? null : text);
            });
            titleText.addEventListener("keydown", (event: KeyboardEvent): void => {
                if (event.key === "Enter") {
                    event.preventDefault();
                    titleText.blur();
                }
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
                // The summary (toggle + editable title) is chrome PM does not manage; only the body is the
                // contentDOM. Keep PM out of the summary's events and DOM mutations.
                stopEvent: (event: Event): boolean => titleBar.contains(event.target as Node),
                ignoreMutation: (mutation: { target: Node }): boolean => titleBar.contains(mutation.target),
            };
        };
    },
});
