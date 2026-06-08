import { CodeMirrorSourceEditor } from "./codemirror-source-editor.js";
import { renderMarkdown } from "./markdown-render.js";
import {
    TiptapVisualEditor,
    type VisualBlockStyle,
    type VisualInlineStyle,
    type VisualStructureStyle,
} from "./tiptap-visual-editor.js";

type EditorMode = "visual" | "source" | "split";
type ActivePane = "source" | "visual";

interface HtmxConfigRequestEvent extends Event {
    detail: {
        parameters: Record<string, string>;
    };
}

/** Web component that edits one Markdown document through an htmx form. */
export class MarkdownEditorElement extends HTMLElement {
    private body: HTMLDivElement | null = null;
    private activePane: ActivePane | null = null;
    private initialised = false;
    private markdown = "";
    private modeButton: HTMLButtonElement | null = null;
    private mode: EditorMode = "visual";
    private panes: HTMLDivElement | null = null;
    private parseError: HTMLDivElement | null = null;
    private preview: HTMLDivElement | null = null;
    private readonly inlineStyleButtons: HTMLButtonElement[] = [];
    private sourceEditor: CodeMirrorSourceEditor | null = null;
    private styleSelect: HTMLSelectElement | null = null;
    private syncingEditors = false;
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
        this.modeButton = this.createModeButton();
        toolbar.append(this.modeButton);
        this.styleSelect = this.createStyleSelect();
        toolbar.append(this.styleSelect);
        toolbar.append(this.createInlineStyleButton("strong", "Bold"));
        toolbar.append(this.createInlineStyleButton("emphasis", "Italic"));
        toolbar.append(this.createInlineStyleButton("code", "Code"));
        toolbar.append(this.createInlineStyleButton("link", "Link"));
        toolbar.append(this.createStructureButton("bullet-list", "Bullet List"));
        toolbar.append(this.createStructureButton("ordered-list", "Ordered List"));
        toolbar.append(this.createStructureButton("blockquote", "Blockquote"));

        return toolbar;
    }

    /** Creates the three-state mode-switching toolbar button. */
    private createModeButton(): HTMLButtonElement {
        const button = document.createElement("button");
        button.className = "markdown-editor__mode-button";
        button.type = "button";
        button.addEventListener("click", (): void => this.switchMode(nextMode(this.mode)));

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

    /** Creates one structural style toolbar button. */
    private createStructureButton(style: VisualStructureStyle, label: string): HTMLButtonElement {
        const button = document.createElement("button");
        button.className = "markdown-editor__structure-button";
        button.textContent = label;
        button.type = "button";
        button.dataset["structureStyle"] = style;
        button.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        button.addEventListener("click", (): void => this.toggleStructure(style));

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
            this.sourceEditor = new CodeMirrorSourceEditor(this.markdown, (): void => this.handleSourceInput());
            this.sourceEditor.element().addEventListener("focusin", (): void => {
                this.activePane = "source";
            });
        }

        if (this.mode === "visual" || this.mode === "split") {
            this.visualEditor = new TiptapVisualEditor(this.markdown, (): void => this.handleVisualInput());
            this.visualEditor.element().addEventListener("focusin", (): void => {
                this.activePane = "visual";
            });
        }

        if (this.mode === "split") {
            this.panes = document.createElement("div");
            this.panes.className = "markdown-editor__split";
            this.panes.append(this.sourceElement(), this.visualEditorElement());
            this.body.append(this.panes);
        } else {
            this.body.append(this.sourceEditor?.element() ?? this.visualEditorElement());
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

        if (this.visualEditor) {
            this.visualEditor.setMarkdown(markdown);
        }

        this.updatePreview();
    }

    /** Applies a visual block style through the active visual editor. */
    private applyBlockStyle(style: string): void {
        if (!isVisualBlockStyle(style)) {
            return;
        }

        if (this.shouldUseSourceCommands()) {
            this.sourceEditor?.applyBlockStyle(style);
            return;
        }

        if (this.visualEditor?.applyBlockStyle(style)) {
            this.handleVisualInput();
        }
    }

    /** Toggles an inline style through the active visual editor. */
    private toggleInlineStyle(style: VisualInlineStyle): void {
        const href = style === "link" ? this.promptForLinkTarget() : undefined;

        if (style === "link" && !href) {
            return;
        }

        if (this.shouldUseSourceCommands()) {
            if (style === "strong") {
                this.sourceEditor?.toggleStrong();
            }

            if (style === "emphasis") {
                this.sourceEditor?.toggleEmphasis();
            }

            if (style === "code") {
                this.sourceEditor?.toggleCode();
            }

            if (style === "link" && href) {
                this.sourceEditor?.toggleLink(href);
            }

            return;
        }

        if (this.visualEditor?.toggleInlineStyle(style, href ?? undefined)) {
            this.handleVisualInput();
        }
    }

    /** Prompts for the link target used by the temporary link toolbar command. */
    private promptForLinkTarget(): string | null {
        const href = window.prompt("Link target");

        if (!href?.trim()) {
            return null;
        }

        return href.trim();
    }

    /** Toggles a structural style through the active editor. */
    private toggleStructure(style: VisualStructureStyle): void {
        if (this.shouldUseSourceCommands()) {
            if (style === "bullet-list") {
                this.sourceEditor?.toggleBulletList();
            }

            if (style === "ordered-list") {
                this.sourceEditor?.toggleOrderedList();
            }

            if (style === "blockquote") {
                this.sourceEditor?.toggleBlockquote();
            }

            return;
        }

        if (this.visualEditor?.toggleStructure(style)) {
            this.handleVisualInput();
        }
    }

    /** Checks whether toolbar commands should target the source editor. */
    private shouldUseSourceCommands(): boolean {
        return Boolean(this.sourceEditor && (!this.visualEditor || this.activePane === "source"));
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
        return this.updatePreviewFromMarkdown(this.toMarkdown());
    }

    /** Handles source editor edits and synchronises any visual split pane. */
    private handleSourceInput(): void {
        if (this.syncingEditors) {
            return;
        }

        const markdown = this.toMarkdown();

        if (!this.updatePreview()) {
            return;
        }

        this.syncVisualEditor(markdown);
        this.dispatchMarkdownChange(markdown);
    }

    /** Handles visual editor edits and synchronises any source split pane. */
    private handleVisualInput(): void {
        if (this.syncingEditors) {
            return;
        }

        const markdown = this.visualEditor?.toMarkdown() ?? this.markdown;

        if (!this.updatePreviewFromMarkdown(markdown)) {
            return;
        }

        this.syncSourceEditor(markdown);
        this.dispatchMarkdownChange(markdown);
    }

    /** Records a valid Markdown change and notifies htmx autosave listeners. */
    private dispatchMarkdownChange(markdown: string): void {
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

    /** Synchronises the source editor from visual Markdown without echoing input. */
    private syncSourceEditor(markdown: string): void {
        if (!this.sourceEditor || this.sourceEditor.toMarkdown() === markdown) {
            return;
        }

        this.syncingEditors = true;
        this.sourceEditor.setMarkdown(markdown);
        this.syncingEditors = false;
    }

    /** Synchronises the visual editor from source Markdown without echoing input. */
    private syncVisualEditor(markdown: string): void {
        if (!this.visualEditor || this.visualEditor.toMarkdown() === markdown) {
            return;
        }

        this.syncingEditors = true;
        this.visualEditor.setMarkdown(markdown);
        this.syncingEditors = false;
    }

    /** Refreshes the preview pane from a known Markdown value. */
    private updatePreviewFromMarkdown(markdown: string): boolean {
        try {
            if (this.preview) {
                this.preview.innerHTML = renderMarkdown(markdown);
            } else {
                renderMarkdown(markdown);
            }
            this.hideParseError();
            return true;
        } catch (error: unknown) {
            if (this.preview) {
                this.preview.innerHTML = "";
            }
            this.showParseError(errorMessage(error));
            return false;
        }
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

        if (this.modeButton) {
            this.modeButton.textContent = modeLabel(this.mode);
            this.modeButton.setAttribute("aria-pressed", "true");
        }

        if (this.styleSelect) {
            this.styleSelect.disabled = !this.visualEditor && !this.sourceEditor;
            this.styleSelect.value = "paragraph";
        }

        for (const button of this.inlineStyleButtons) {
            button.disabled = !this.visualEditor && !this.sourceEditor;
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

/** Returns the next mode in the toolbar cycle. */
function nextMode(mode: EditorMode): EditorMode {
    if (mode === "visual") {
        return "source";
    }

    if (mode === "source") {
        return "split";
    }

    return "visual";
}

/** Returns the display label for a toolbar mode. */
function modeLabel(mode: EditorMode): string {
    if (mode === "source") {
        return "Markdown";
    }

    if (mode === "split") {
        return "Split";
    }

    return "Visual";
}
