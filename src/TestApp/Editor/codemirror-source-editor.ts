import { markdown } from "@codemirror/lang-markdown";
import { basicSetup, EditorView } from "codemirror";

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

    /** Serialises the current source document to Markdown. */
    public toMarkdown(): string {
        return this.view.state.doc.toString();
    }

    /** Releases CodeMirror resources when the source editor is removed. */
    public destroy(): void {
        this.view.destroy();
    }
}
