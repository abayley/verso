import { Editor, type JSONContent, type SetContentOptions } from "@tiptap/core";
import Heading from "@tiptap/extension-heading";
import { Markdown } from "@tiptap/markdown";
import StarterKit from "@tiptap/starter-kit";

/** Callback fired when the visual editor content changes. */
export type TiptapChangeHandler = () => void;

/** Supported visual block styles exposed by the editor toolbar. */
export type VisualBlockStyle = "paragraph" | "heading-1" | "heading-2" | "heading-3";

/** Supported visual inline styles exposed by the editor toolbar. */
export type VisualInlineStyle = "strong" | "emphasis" | "code" | "link";

/** Supported visual structure commands exposed by the editor toolbar. */
export type VisualStructureStyle = "bullet-list" | "ordered-list" | "blockquote";

type MarkdownSetContentOptions = SetContentOptions & {
    contentType: "markdown";
};

const HeadingWithoutInputRules = Heading.extend({
    /** Keeps heading nodes available while preventing typed hash shortcuts. */
    addInputRules() {
        return [];
    },
});

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
                StarterKit.configure({
                    heading: false,
                }),
                HeadingWithoutInputRules,
                Markdown.configure({
                    markedOptions: {
                        gfm: true,
                    },
                }),
            ],
            injectCSS: false,
            onUpdate: (): void => {
                if (this.applyListMarkerShortcut()) {
                    return;
                }

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
        return escapeLiteralParagraphMarkers(this.editor.getMarkdown(), this.editor.getJSON());
    }

    /** Replaces the current visual document from Markdown. */
    public setMarkdown(markdown: string): void {
        const options: MarkdownSetContentOptions = {
            contentType: "markdown",
            emitUpdate: false,
        };

        this.editor.commands.setContent(markdown, options);
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
    public toggleInlineStyle(style: VisualInlineStyle, href?: string): boolean {
        const selection = this.currentVisualSelection();

        switch (style) {
            case "strong": {
                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleBold().run(),
                );
            }

            case "emphasis": {
                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleItalic().run(),
                );
            }

            case "code": {
                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleCode().run(),
                );
            }

            case "link": {
                if (!href) {
                    return false;
                }

                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().setLink({ href }).run(),
                );
            }
        }
    }

    /** Toggles one supported structural style at the current visual selection. */
    public toggleStructure(style: VisualStructureStyle): boolean {
        if (style === "bullet-list") {
            return this.editor.chain().focus().toggleBulletList().run();
        }

        if (style === "ordered-list") {
            return this.editor.chain().focus().toggleOrderedList().run();
        }

        if (style === "blockquote") {
            return this.editor.chain().focus().toggleBlockquote().run();
        }

        return false;
    }

    /** Releases Tiptap resources when the custom element disconnects. */
    public destroy(): void {
        this.editor.destroy();
    }

    /** Restores the visual selection before running a toolbar command. */
    private withCurrentSelection(
        selection: { from: number; to: number } | null,
        command: (editor: Editor) => boolean,
    ): boolean {
        if (selection) {
            this.editor.commands.setTextSelection(selection);
        }

        return command(this.editor);
    }

    /** Converts supported literal list markers into list nodes while typing. */
    private applyListMarkerShortcut(): boolean {
        const text = this.editor.getText();

        if (text === "- ") {
            this.editor.chain().clearContent().toggleBulletList().focus().run();
            return true;
        }

        if (text === "1. ") {
            this.editor.chain().clearContent().toggleOrderedList().focus().run();
            return true;
        }

        return false;
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

/** Escapes paragraph text that would otherwise be parsed back as Markdown block syntax. */
function escapeLiteralParagraphMarkers(markdown: string, document: JSONContent): string {
    const blocks = markdown.split("\n\n");
    const nodes = document.content ?? [];

    return blocks
        .map((block: string, index: number): string => {
            if (nodes[index]?.type !== "paragraph") {
                return block;
            }

            return block.replace(/^(#{1,6}\s)/u, "\\$1");
        })
        .join("\n\n");
}
