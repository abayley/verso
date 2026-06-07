import { CodeMirrorSourceEditor } from "./codemirror-source-editor.js";
import { renderMarkdown } from "./markdown-render.js";
import { TiptapVisualEditor, type VisualBlockStyle, type VisualInlineStyle } from "./tiptap-visual-editor.js";

type EditorMode = "visual" | "source" | "split";

interface HtmxConfigRequestEvent extends Event {
    detail: {
        parameters: Record<string, string>;
    };
}

/** Web component that edits one Markdown document through an htmx form. */
export class MarkdownEditorElement extends HTMLElement {
    private body: HTMLDivElement | null = null;
    private initialised = false;
    private markdown = "";
    private mode: EditorMode = "visual";
    private panes: HTMLDivElement | null = null;
    private parseError: HTMLDivElement | null = null;
    private preview: HTMLDivElement | null = null;
    private readonly inlineStyleButtons: HTMLButtonElement[] = [];
    private sourceEditor: CodeMirrorSourceEditor | null = null;
    private styleSelect: HTMLSelectElement | null = null;
    private toolbar: HTMLDivElement | null = null;
    private visualEditor: TiptapVisualEditor | null = null;

    /** Starts asynchronous element initialisation after connection. */
    connectedCallback(): void {
        if (this.initialised) {
            return;
        }

        window.setTimeout((): void => {
            this.initialise().catch((error: unknown): void => {
                console.error(error);
            });
        }, 0);
    }

    /** Cleans up editor resources when the element leaves the document. */
    disconnectedCallback(): void {
        this.visualEditor?.destroy();
        this.visualEditor = null;
    }

    /** Initialises the editor UI from inline content or a Markdown `src`. */
    private async initialise(): Promise<void> {
        if (this.initialised) {
            return;
        }

        this.initialised = true;
        this.markdown = await this.loadMarkdown();
        this.mode = this.editorMode();
        this.textContent = "";

        this.toolbar = this.createToolbar();
        this.body = document.createElement("div");
        this.body.className = "markdown-editor__body";
        this.preview = document.createElement("div");
        this.preview.className = "markdown-editor__preview";
        this.preview.setAttribute("aria-live", "polite");
        this.parseError = document.createElement("div");
        this.parseError.className = "markdown-editor__error";
        this.parseError.setAttribute("role", "alert");
        this.parseError.hidden = true;

        this.append(this.toolbar, this.body, this.parseError);
        this.renderMode();
        this.updateToolbarState();
        this.updatePreview();
        this.configureFormSubmission();
    }

    /** Creates the top editor toolbar. */
    private createToolbar(): HTMLDivElement {
        const toolbar = document.createElement("div");
        toolbar.className = "markdown-editor__toolbar";
        toolbar.setAttribute("role", "toolbar");
        toolbar.append(this.createModeButton("visual", "Visual"));
        toolbar.append(this.createModeButton("source", "Markdown"));
        toolbar.append(this.createModeButton("split", "Split"));
        this.styleSelect = this.createStyleSelect();
        toolbar.append(this.styleSelect);
        toolbar.append(this.createInlineStyleButton("strong", "Bold"));

        return toolbar;
    }

    /** Creates one mode-switching toolbar button. */
    private createModeButton(mode: EditorMode, label: string): HTMLButtonElement {
        const button = document.createElement("button");
        button.className = "markdown-editor__mode-button";
        button.textContent = label;
        button.type = "button";
        button.dataset["mode"] = mode;
        button.addEventListener("click", (): void => this.switchMode(mode));

        return button;
    }

    /** Creates the block style toolbar control. */
    private createStyleSelect(): HTMLSelectElement {
        const select = document.createElement("select");
        select.className = "markdown-editor__style-select";
        select.setAttribute("aria-label", "Block style");
        select.append(
            this.createStyleOption("paragraph", "Paragraph"),
            this.createStyleOption("heading-1", "Heading 1"),
            this.createStyleOption("heading-2", "Heading 2"),
            this.createStyleOption("heading-3", "Heading 3"),
        );
        select.addEventListener("change", (): void => this.applyBlockStyle(select.value));

        return select;
    }

    /** Creates one option in the block style toolbar control. */
    private createStyleOption(value: VisualBlockStyle, label: string): HTMLOptionElement {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = label;

        return option;
    }

    /** Creates one inline style toolbar button. */
    private createInlineStyleButton(style: VisualInlineStyle, label: string): HTMLButtonElement {
        const button = document.createElement("button");
        button.className = "markdown-editor__inline-button";
        button.textContent = label;
        button.type = "button";
        button.dataset["inlineStyle"] = style;
        button.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        button.addEventListener("click", (): void => this.toggleInlineStyle(style));
        this.inlineStyleButtons.push(button);

        return button;
    }

    /** Re-renders the editor body for the current mode. */
    private renderMode(): void {
        if (!this.body) {
            return;
        }

        this.sourceEditor?.destroy();
        this.visualEditor?.destroy();
        this.sourceEditor = null;
        this.visualEditor = null;
        this.panes = null;
        this.body.textContent = "";

        if (this.mode === "source" || this.mode === "split") {
            this.sourceEditor = new CodeMirrorSourceEditor(this.markdown, (): void => this.handleInput());
        }

        if (this.mode === "visual") {
            this.visualEditor = new TiptapVisualEditor(this.markdown, (): void => this.handleInput());
        }

        if (this.mode === "split") {
            this.panes = document.createElement("div");
            this.panes.className = "markdown-editor__split";
            this.panes.append(this.sourceElement(), this.previewElement());
            this.body.append(this.panes);
        } else {
            this.body.append(this.sourceEditor?.element() ?? this.visualEditorElement(), this.previewElement());
        }
    }

    /** Returns the selected editor mode, defaulting unknown values to visual. */
    private editorMode(): EditorMode {
        const mode = this.getAttribute("mode");

        if (mode === "source" || mode === "split") {
            return mode;
        }

        return "visual";
    }

    /** Loads Markdown from the `src` attribute, or from inline element text. */
    private async loadMarkdown(): Promise<string> {
        const src = this.getAttribute("src");

        if (!src) {
            return this.textContent.trim();
        }

        const response = await fetch(src, {
            headers: {
                Accept: "text/markdown",
            },
        });

        if (!response.ok) {
            throw new Error(`Failed to load Markdown document: ${response.status}`);
        }

        return response.text();
    }

    /** Serialises the current editor value to Markdown. */
    public toMarkdown(): string {
        if (this.sourceEditor) {
            return this.sourceEditor.toMarkdown();
        }

        if (!this.visualEditor) {
            return this.markdown;
        }

        return this.visualEditor.toMarkdown();
    }

    /** Replaces the current Markdown document and refreshes the active editor. */
    public setMarkdown(markdown: string): void {
        this.markdown = markdown;

        if (this.sourceEditor) {
            this.sourceEditor.setMarkdown(markdown);
        }

        this.updatePreview();
    }

    /** Applies a visual block style through the active visual editor. */
    private applyBlockStyle(style: string): void {
        if (!this.visualEditor || !isVisualBlockStyle(style)) {
            return;
        }

        if (this.visualEditor.applyBlockStyle(style)) {
            this.handleInput();
        }
    }

    /** Toggles an inline style through the active visual editor. */
    private toggleInlineStyle(style: VisualInlineStyle): void {
        if (!this.visualEditor) {
            return;
        }

        if (this.visualEditor.toggleInlineStyle(style)) {
            this.handleInput();
        }
    }

    /** Switches the active editor mode after validating the current Markdown. */
    private switchMode(mode: EditorMode): void {
        const markdown = this.toMarkdown();

        try {
            renderMarkdown(markdown);
        } catch (error: unknown) {
            this.showParseError(errorMessage(error));
            return;
        }

        this.markdown = markdown;
        this.mode = mode;
        this.setAttribute("mode", mode);
        this.renderMode();
        this.updateToolbarState();
        this.updatePreview();
    }

    /** Refreshes the preview pane from the current Markdown value. */
    private updatePreview(): boolean {
        if (!this.preview) {
            return true;
        }

        try {
            this.preview.innerHTML = renderMarkdown(this.toMarkdown());
            this.hideParseError();
            return true;
        } catch (error: unknown) {
            this.preview.innerHTML = "";
            this.showParseError(errorMessage(error));
            return false;
        }
    }

    /** Handles local edits and notifies htmx autosave listeners. */
    private handleInput(): void {
        const markdown = this.toMarkdown();

        if (!this.updatePreview()) {
            return;
        }

        this.markdown = markdown;
        this.dispatchEvent(
            new CustomEvent("editor:changed", {
                bubbles: true,
                detail: {
                    markdown,
                },
            }),
        );
    }

    /** Hooks the editor value into the surrounding htmx form submission. */
    private configureFormSubmission(): void {
        const form = this.closest("form");
        const field = document.getElementById("markdown-field");

        if (!(form instanceof HTMLFormElement) || !(field instanceof HTMLInputElement)) {
            return;
        }

        form.addEventListener("htmx:configRequest", (event: Event): void => {
            const markdown = this.toMarkdown();
            const htmxEvent = event as HtmxConfigRequestEvent;

            field.value = markdown;
            htmxEvent.detail.parameters["markdown"] = markdown;
        });
    }

    /** Shows the latest Markdown parse error in the editor chrome. */
    private showParseError(message: string): void {
        if (!this.parseError) {
            return;
        }

        this.parseError.textContent = message;
        this.parseError.hidden = false;
    }

    /** Clears any visible Markdown parse error. */
    private hideParseError(): void {
        if (!this.parseError) {
            return;
        }

        this.parseError.textContent = "";
        this.parseError.hidden = true;
    }

    /** Returns the visual editor element after construction. */
    private visualEditorElement(): HTMLDivElement {
        if (!this.visualEditor) {
            throw new Error("Markdown editor surface was not created.");
        }

        return this.visualEditor.element();
    }

    /** Returns the preview element after construction. */
    private previewElement(): HTMLDivElement {
        if (!this.preview) {
            throw new Error("Markdown preview element was not created.");
        }

        return this.preview;
    }

    /** Returns the source editor element after construction. */
    private sourceElement(): HTMLDivElement {
        if (!this.sourceEditor) {
            throw new Error("Markdown source editor was not created.");
        }

        return this.sourceEditor.element();
    }

    /** Reflects the current editor mode into the toolbar buttons. */
    private updateToolbarState(): void {
        if (!this.toolbar) {
            return;
        }

        for (const button of this.toolbar.querySelectorAll("button")) {
            const selected = button.dataset["mode"] === this.mode;
            button.setAttribute("aria-pressed", selected ? "true" : "false");
        }

        if (this.styleSelect) {
            this.styleSelect.disabled = this.mode !== "visual";
            this.styleSelect.value = "paragraph";
        }

        for (const button of this.inlineStyleButtons) {
            button.disabled = this.mode !== "visual";
        }
    }
}

/** Extracts a displayable error message from a thrown value. */
function errorMessage(error: unknown): string {
    if (error instanceof Error) {
        return error.message;
    }

    return "Markdown could not be parsed.";
}

/** Checks that a toolbar value is a supported visual block style. */
function isVisualBlockStyle(style: string): style is VisualBlockStyle {
    return style === "paragraph" || style === "heading-1" || style === "heading-2" || style === "heading-3";
}
