import { Editor } from "@tiptap/core";
import { Markdown } from "@tiptap/markdown";
import StarterKit from "@tiptap/starter-kit";

/** Callback fired when the visual editor content changes. */
export type TiptapChangeHandler = () => void;

/** Supported visual block styles exposed by the editor toolbar. */
export type VisualBlockStyle = "paragraph" | "heading-1" | "heading-2" | "heading-3";

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

    /** Releases Tiptap resources when the custom element disconnects. */
    public destroy(): void {
        this.editor.destroy();
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
