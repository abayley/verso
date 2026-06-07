import { renderMarkdown } from "./markdown-render.js";
import { TiptapVisualEditor } from "./tiptap-visual-editor.js";

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
    private source: HTMLTextAreaElement | null = null;
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

    /** Re-renders the editor body for the current mode. */
    private renderMode(): void {
        if (!this.body) {
            return;
        }

        this.visualEditor?.destroy();
        this.visualEditor = null;
        this.source = null;
        this.panes = null;
        this.body.textContent = "";

        if (this.mode === "source" || this.mode === "split") {
            this.source = this.createSourceEditor();
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
            this.body.append(this.source ?? this.visualEditorElement(), this.previewElement());
        }
    }

    /** Creates the raw Markdown source editor. */
    private createSourceEditor(): HTMLTextAreaElement {
        const source = document.createElement("textarea");
        source.className = "markdown-editor__source";
        source.value = this.markdown;
        source.addEventListener("input", (): void => this.handleInput());

        return source;
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
        if (this.source) {
            return this.source.value;
        }

        if (!this.visualEditor) {
            return this.markdown;
        }

        return this.visualEditor.toMarkdown();
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
    private sourceElement(): HTMLTextAreaElement {
        if (!this.source) {
            throw new Error("Markdown source textarea was not created.");
        }

        return this.source;
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
    }
}

/** Extracts a displayable error message from a thrown value. */
function errorMessage(error: unknown): string {
    if (error instanceof Error) {
        return error.message;
    }

    return "Markdown could not be parsed.";
}
