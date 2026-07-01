import type { Editor } from "@tiptap/core";
import type { Node as ProseMirrorNode } from "@tiptap/pm/model";
import type { EditorView } from "@tiptap/pm/view";

/** The label shown for a code block with no language set (a plain, unhighlighted block). */
const PLAIN_LABEL = "Plain text";

/**
 * The NodeView for the fenced-code-block node (RFC-0033). It keeps the code-block DOM shape a `<pre>` root
 * with a `<code class="language-...">` content element, so both the serialiser (`codeBlockFromElement`, which
 * keys on `tagName === "PRE"` and reads `code.textContent`) and CodeBlockLowlight's decoration plugin (which
 * targets the content) keep working unchanged. On top of that content it adds, while editing, a language
 * picker that sets the node's `language` attribute; in the read view it shows the language as a muted label.
 * The Mermaid diagram behaviour is layered on in a later slice.
 */
export class CodeBlockView {
    public readonly dom: HTMLPreElement;
    public readonly contentDOM: HTMLElement;
    private readonly toolbar: HTMLDivElement;
    private readonly picker: HTMLElement;
    private readonly label: HTMLElement;
    private node: ProseMirrorNode;
    private readonly editor: Editor;
    private readonly getPos: () => number | undefined;
    private readonly languages: readonly string[];

    public constructor(
        node: ProseMirrorNode,
        editor: Editor,
        getPos: () => number | undefined,
        languages: readonly string[],
    ) {
        this.node = node;
        this.editor = editor;
        this.getPos = getPos;
        this.languages = languages;

        this.dom = document.createElement("pre");
        this.toolbar = document.createElement("div");
        this.toolbar.className = "markdown-editor__code-toolbar";
        this.toolbar.contentEditable = "false";
        this.label = document.createElement("span");
        this.label.className = "markdown-editor__code-language";
        this.picker = this.createPicker();
        this.toolbar.append(this.picker, this.label);

        this.contentDOM = document.createElement("code");
        this.dom.append(this.toolbar, this.contentDOM);

        this.render();
    }

    /** Builds the Web Awesome language dropdown; selecting an item sets the node's language attribute. */
    private createPicker(): HTMLElement {
        const dropdown = document.createElement("wa-dropdown");
        dropdown.className = "markdown-editor__code-language-dropdown";
        dropdown.setAttribute("size", "s");

        const trigger = document.createElement("wa-button");
        trigger.className = "markdown-editor__button markdown-editor__code-language-trigger";
        trigger.setAttribute("slot", "trigger");
        trigger.setAttribute("appearance", "plain");
        trigger.setAttribute("size", "s");
        trigger.setAttribute("with-caret", "");
        trigger.setAttribute("type", "button");
        dropdown.append(trigger);

        const entries: [string, string][] = [
            ["", PLAIN_LABEL],
            ...this.languages.map((lang): [string, string] => [lang, lang]),
        ];

        for (const [value, label] of entries) {
            const item = document.createElement("wa-dropdown-item");
            item.setAttribute("value", value);
            item.textContent = label;
            dropdown.append(item);
        }

        dropdown.addEventListener("wa-select", (event: Event): void => {
            const item = (event as CustomEvent<{ item?: Element }>).detail?.item;
            const value = item?.getAttribute("value") ?? "";
            this.setLanguage(value);
        });

        return dropdown;
    }

    /** Sets the code block's `language` attribute at this node's position. */
    private setLanguage(language: string): void {
        const pos = this.getPos();

        if (pos === undefined) {
            return;
        }

        const view: EditorView = this.editor.view;
        const attrs = { ...this.node.attrs, language: language || null };
        view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, attrs));
        this.editor.commands.focus();
    }

    /** The node's language, or the empty string for a plain block. */
    private language(): string {
        return typeof this.node.attrs["language"] === "string" ? this.node.attrs["language"] : "";
    }

    /** Reflects the current language and edit/read state onto the DOM. */
    private render(): void {
        const language = this.language();
        this.contentDOM.className = language ? `language-${language}` : "";
        const triggerLabel = language || PLAIN_LABEL;
        const trigger = this.picker.querySelector(".markdown-editor__code-language-trigger");

        if (trigger) {
            trigger.textContent = triggerLabel;
        }

        this.label.textContent = triggerLabel;
        const editable = this.editor.isEditable;
        this.picker.hidden = !editable;
        // In the read view the language shows as a muted label; while editing, the picker carries it instead.
        this.label.hidden = editable;
    }

    /** Keeps the NodeView on attribute/content changes to the same node type (so decorations re-apply). */
    public update(node: ProseMirrorNode): boolean {
        if (node.type !== this.node.type) {
            return false;
        }

        this.node = node;
        this.render();

        return true;
    }

    /** Chrome (toolbar) is not editor content: never treat its mutations as document changes. */
    public ignoreMutation(mutation: MutationRecord | { type: "selection"; target: Node }): boolean {
        if (mutation.type === "selection") {
            return false;
        }

        return !this.contentDOM.contains(mutation.target as Node);
    }

    /** Let the picker handle its own pointer/keyboard events rather than the editor. */
    public stopEvent(event: Event): boolean {
        return this.toolbar.contains(event.target as Node);
    }
}
