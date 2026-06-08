import { markdown } from "@codemirror/lang-markdown";
import { basicSetup, EditorView } from "codemirror";
import type { VisualBlockStyle } from "./tiptap-visual-editor.js";

/** Callback fired when the source editor content changes. */
export type CodeMirrorChangeHandler = () => void;

/** Markdown source editor adapter around CodeMirror. */
export class CodeMirrorSourceEditor {
    private readonly root: HTMLDivElement;
    private readonly view: EditorView;

    /** Creates a CodeMirror editor mounted inside a stable root element. */
    public constructor(markdownText: string, onChange: CodeMirrorChangeHandler) {
        this.root = document.createElement("div");
        this.root.className = "markdown-editor__source";

        this.view = new EditorView({
            doc: markdownText,
            extensions: [
                basicSetup,
                markdown(),
                EditorView.lineWrapping,
                EditorView.updateListener.of((update): void => {
                    if (update.docChanged) {
                        onChange();
                    }
                }),
            ],
            parent: this.root,
        });
    }

    /** Returns the root element that hosts the CodeMirror editor. */
    public element(): HTMLDivElement {
        return this.root;
    }

    /** Replaces the current source document. */
    public setMarkdown(markdownText: string): void {
        this.view.dispatch({
            changes: {
                from: 0,
                insert: markdownText,
                to: this.view.state.doc.length,
            },
        });
    }

    /** Applies a block style to the source line containing the cursor. */
    public applyBlockStyle(style: VisualBlockStyle): boolean {
        const selection = this.currentSourceSelection();
        const line = this.view.state.doc.lineAt(selection?.to ?? this.view.state.selection.main.head);
        const lineText = line.text.replace(/^#{1,6}\s+/, "");
        const replacement = style === "paragraph" ? lineText : `${headingPrefix(style)} ${lineText}`;

        this.view.dispatch({
            changes: {
                from: line.from,
                insert: replacement,
                to: line.to,
            },
        });

        return true;
    }

    /** Toggles Markdown strong markers around the current source selection. */
    public toggleStrong(): boolean {
        return this.wrapSelection("**", "**");
    }

    /** Toggles Markdown emphasis markers around the current source selection. */
    public toggleEmphasis(): boolean {
        return this.wrapSelection("*", "*");
    }

    /** Toggles Markdown inline code markers around the current source selection. */
    public toggleCode(): boolean {
        return this.wrapSelection("`", "`");
    }

    /** Serialises the current source document to Markdown. */
    public toMarkdown(): string {
        return this.view.state.doc.toString();
    }

    /** Releases CodeMirror resources when the source editor is removed. */
    public destroy(): void {
        this.view.destroy();
    }

    /** Wraps the current source selection with Markdown marker text. */
    private wrapSelection(prefix: string, suffix: string): boolean {
        const selection = this.currentSourceSelection();

        if (!selection || selection.from === selection.to) {
            return false;
        }

        const selectedText = this.view.state.doc.sliceString(selection.from, selection.to);
        this.view.dispatch({
            changes: {
                from: selection.from,
                insert: `${prefix}${selectedText}${suffix}`,
                to: selection.to,
            },
        });

        return true;
    }

    /** Converts the current browser selection into CodeMirror document positions. */
    private currentSourceSelection(): { from: number; to: number } | null {
        const selection = window.getSelection();

        if (!selection?.anchorNode || !selection.focusNode) {
            return null;
        }

        if (!this.root.contains(selection.anchorNode) || !this.root.contains(selection.focusNode)) {
            return null;
        }

        const anchor = this.view.posAtDOM(selection.anchorNode, selection.anchorOffset);
        const focus = this.view.posAtDOM(selection.focusNode, selection.focusOffset);

        return {
            from: Math.min(anchor, focus),
            to: Math.max(anchor, focus),
        };
    }
}

/** Converts a toolbar style identifier into a Markdown heading prefix. */
function headingPrefix(style: Exclude<VisualBlockStyle, "paragraph">): string {
    if (style === "heading-1") {
        return "#";
    }

    if (style === "heading-2") {
        return "##";
    }

    return "###";
}
