import { Editor } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import StarterKit from "@tiptap/starter-kit";

/** Callback fired when the visual editor content changes. */
export type TiptapChangeHandler = () => void;

/** Supported visual block styles exposed by the editor toolbar. */
export type VisualBlockStyle = "paragraph" | "heading-1" | "heading-2" | "heading-3";

/** Supported visual inline styles exposed by the editor toolbar. */
export type VisualInlineStyle = "strong";

/** Markdown-in/Markdown-out adapter around Tiptap's visual editor. */
export class TiptapVisualEditor {
    private readonly editor: Editor;
    private readonly root: HTMLDivElement;

    /** Creates a Tiptap editor mounted inside a stable root element. */
    public constructor(markdown: string, onChange: TiptapChangeHandler) {
        this.root = document.createElement("div");
        this.root.className = "markdown-editor__surface";

        this.editor = new Editor({
            content: markdown,
            contentType: "markdown",
            element: this.root,
            extensions: [
                StarterKit,
                Markdown.configure({
                    markedOptions: {
                        gfm: true,
                    },
                }),
            ],
            injectCSS: false,
            onUpdate: (): void => {
                onChange();
            },
        });
    }

    /** Returns the root element that hosts the Tiptap editor. */
    public element(): HTMLDivElement {
        return this.root;
    }

    /** Serialises the current Tiptap document to Markdown. */
    public toMarkdown(): string {
        return this.editor.getMarkdown();
    }

    /** Applies one supported block style at the current visual selection. */
    public applyBlockStyle(style: VisualBlockStyle): boolean {
        if (style === "paragraph") {
            return this.editor.chain().focus().setParagraph().run();
        }

        return this.editor
            .chain()
            .focus()
            .setHeading({
                level: headingLevel(style),
            })
            .run();
    }

    /** Toggles one supported inline style at the current visual selection. */
    public toggleInlineStyle(style: VisualInlineStyle): boolean {
        const selection = this.currentVisualSelection();

        switch (style) {
            case "strong": {
                const command = this.editor.chain();

                if (selection) {
                    command.setTextSelection(selection);
                }

                return command.focus().toggleBold().run();
            }
        }
    }

    /** Releases Tiptap resources when the custom element disconnects. */
    public destroy(): void {
        this.editor.destroy();
    }

    /** Converts the current browser selection into Tiptap document positions. */
    private currentVisualSelection(): { from: number; to: number } | null {
        const selection = window.getSelection();

        if (!selection?.anchorNode || !selection.focusNode) {
            return null;
        }

        if (!this.root.contains(selection.anchorNode) || !this.root.contains(selection.focusNode)) {
            return null;
        }

        const anchor = this.editor.view.posAtDOM(selection.anchorNode, selection.anchorOffset);
        const focus = this.editor.view.posAtDOM(selection.focusNode, selection.focusOffset);

        return {
            from: Math.min(anchor, focus),
            to: Math.max(anchor, focus),
        };
    }
}

/** Converts toolbar style identifiers into Tiptap heading levels. */
function headingLevel(style: Exclude<VisualBlockStyle, "paragraph">): 1 | 2 | 3 {
    if (style === "heading-1") {
        return 1;
    }

    if (style === "heading-2") {
        return 2;
    }

    return 3;
}
