import { renderMarkdown } from "./markdown-render.js";
import { documentFromElements, documentToMarkdown } from "./markdown-serialise.js";

type EditorMode = "visual" | "source" | "split";

interface HtmxConfigRequestEvent extends Event {
    detail: {
        parameters: Record<string, string>;
    };
}

/** Web component that edits one Markdown document through an htmx form. */
export class MarkdownEditorElement extends HTMLElement {
    private editor: HTMLDivElement | null = null;
    private initialised = false;
    private markdown = "";
    private mode: EditorMode = "visual";
    private panes: HTMLDivElement | null = null;
    private parseError: HTMLDivElement | null = null;
    private preview: HTMLDivElement | null = null;
    private source: HTMLTextAreaElement | null = null;

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

    /** Initialises the editor UI from inline content or a Markdown `src`. */
    private async initialise(): Promise<void> {
        if (this.initialised) {
            return;
        }

        this.initialised = true;
        this.markdown = await this.loadMarkdown();
        this.mode = this.editorMode();
        this.textContent = "";

        if (this.mode === "source" || this.mode === "split") {
            this.source = document.createElement("textarea");
            this.source.className = "markdown-editor__source";
            this.source.value = this.markdown;
            this.source.addEventListener("input", (): void => this.handleInput());
        }

        if (this.mode === "visual") {
            this.editor = document.createElement("div");
            this.editor.className = "markdown-editor__surface";
            this.editor.contentEditable = "true";
            this.editor.innerHTML = renderMarkdown(this.markdown);
            this.editor.addEventListener("input", (): void => this.handleInput());
        }

        this.preview = document.createElement("div");
        this.preview.className = "markdown-editor__preview";
        this.preview.setAttribute("aria-live", "polite");
        this.parseError = document.createElement("div");
        this.parseError.className = "markdown-editor__error";
        this.parseError.setAttribute("role", "alert");
        this.parseError.hidden = true;

        if (this.mode === "split") {
            this.panes = document.createElement("div");
            this.panes.className = "markdown-editor__split";
            this.panes.append(this.sourceElement(), this.preview);
            this.append(this.panes, this.parseError);
        } else {
            this.append(this.source ?? this.editorElement(), this.preview, this.parseError);
        }

        this.updatePreview();
        this.configureFormSubmission();
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

        if (!this.editor) {
            return this.markdown;
        }

        return documentToMarkdown(documentFromElements(this.editor.children));
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
    private editorElement(): HTMLDivElement {
        if (!this.editor) {
            throw new Error("Markdown editor surface was not created.");
        }

        return this.editor;
    }

    /** Returns the source editor element after construction. */
    private sourceElement(): HTMLTextAreaElement {
        if (!this.source) {
            throw new Error("Markdown source textarea was not created.");
        }

        return this.source;
    }
}

/** Extracts a displayable error message from a thrown value. */
function errorMessage(error: unknown): string {
    if (error instanceof Error) {
        return error.message;
    }

    return "Markdown could not be parsed.";
}
