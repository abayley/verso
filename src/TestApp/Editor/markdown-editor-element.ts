import { CodeMirrorSourceEditor, type CodeMirrorSourceSelection } from "./codemirror-source-editor.js";
import { renderMarkdown } from "./markdown-render.js";
import {
    TiptapVisualEditor,
    type VisualBlockStyle,
    type VisualInlineStyle,
    type VisualStructureStyle,
} from "./tiptap-visual-editor.js";

type EditorMode = "visual" | "source" | "split";
type EditorTheme = "light" | "dark" | "match-system";
type ActivePane = "source" | "visual";
type SaveState = "clean" | "dirty" | "saving" | "retry";
type ToolbarButtonElement = HTMLElement;

interface WaDropdownSelectEvent extends Event {
    detail: {
        item: Element;
    };
}

interface HtmxConfigRequestEvent extends Event {
    detail: {
        parameters: Record<string, string>;
    };
}

interface HtmxAfterRequestEvent extends Event {
    detail: {
        successful?: boolean;
        xhr?: {
            status: number;
        };
    };
}

/** Web component that edits one Markdown document through an htmx form. */
export class MarkdownEditorElement extends HTMLElement {
    private body: HTMLDivElement | null = null;
    private activePane: ActivePane | null = null;
    private initialised = false;
    private markdown = "";
    private modeGroup: HTMLElement | null = null;
    private mode: EditorMode = "visual";
    private panes: HTMLDivElement | null = null;
    private parseError: HTMLDivElement | null = null;
    private preview: HTMLDivElement | null = null;
    private readonly inlineStyleButtons: ToolbarButtonElement[] = [];
    private linkEditor: HTMLDivElement | null = null;
    private linkTargetInput: HTMLInputElement | null = null;
    private lastSubmittedMarkdown = "";
    private pendingLink = false;
    private pendingLinkSourceSelection: CodeMirrorSourceSelection | null = null;
    private saveButton: ToolbarButtonElement | null = null;
    private saveError: HTMLSpanElement | null = null;
    private saveStartedAt = 0;
    private saveState: SaveState = "clean";
    private saveTransitionTimeout: number | null = null;
    private saveTimeout: number | null = null;
    private sourceEditor: CodeMirrorSourceEditor | null = null;
    private styleDropdown: HTMLElement | null = null;
    private styleTrigger: ToolbarButtonElement | null = null;
    private syncingEditors = false;
    private theme: EditorTheme = "match-system";
    private themeGroup: HTMLElement | null = null;
    private readonly handleSystemThemeChange = (): void => {
        if (this.theme === "match-system") {
            this.applyDocumentTheme();
        }
    };
    private readonly handleDocumentPointerDown = (event: PointerEvent): void => {
        if (!this.pendingLink || !this.linkEditor) {
            return;
        }

        const target = event.target;

        if (target instanceof Node && this.linkEditor.contains(target)) {
            return;
        }

        this.hideLinkEditor();
    };
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
        this.systemThemeQuery()?.removeEventListener("change", this.handleSystemThemeChange);
        document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
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
        this.theme = this.editorTheme();
        this.textContent = "";

        this.toolbar = this.createToolbar();
        this.linkEditor = this.createLinkEditor();
        this.body = document.createElement("div");
        this.body.className = "markdown-editor__body";
        this.parseError = document.createElement("div");
        this.parseError.className = "markdown-editor__error";
        this.parseError.setAttribute("role", "alert");
        this.parseError.hidden = true;

        this.append(this.toolbar, this.linkEditor, this.body, this.parseError);
        this.renderMode();
        this.updateToolbarState();
        this.updatePreview();
        this.configureFormSubmission();
        this.systemThemeQuery()?.addEventListener("change", this.handleSystemThemeChange);
    }

    /** Creates the top editor toolbar. */
    private createToolbar(): HTMLDivElement {
        const toolbar = document.createElement("div");
        toolbar.className = "markdown-editor__toolbar";
        toolbar.setAttribute("role", "toolbar");
        this.modeGroup = this.createModeGroup();
        toolbar.append(this.modeGroup);
        this.styleDropdown = this.createStyleDropdown();
        toolbar.append(this.styleDropdown);
        toolbar.append(
            this.createToolbarButtonGroup(
                this.createInlineStyleButton("strong", "Bold", "bold"),
                this.createInlineStyleButton("emphasis", "Italic", "italic"),
                this.createInlineStyleButton("strikethrough", "Strike", "strikethrough"),
                this.createInlineStyleButton("code", "Code", "code"),
                this.createInlineStyleButton("link", "Link", "link"),
            ),
            this.createToolbarButtonGroup(
                this.createStructureButton("bullet-list", "Bullet List", "list"),
                this.createStructureButton("ordered-list", "Ordered List", "list-ol"),
                this.createStructureButton("blockquote", "Blockquote", "quote-left"),
                this.createStructureButton("code-block", "Code Block", "file-code"),
                this.createStructureButton("thematic-break", "Horizontal rule", "window-minimize"),
            ),
        );
        toolbar.append(this.createSaveError());
        toolbar.append(this.createSaveButton());
        this.themeGroup = this.createThemeGroup();
        toolbar.append(this.themeGroup);

        return toolbar;
    }

    /** Creates the editor view mode radio group. */
    private createModeGroup(): HTMLElement {
        const group = document.createElement("wa-radio-group");
        group.className = "markdown-editor__mode-group";
        group.setAttribute("aria-label", "Editor view mode");
        group.setAttribute("orientation", "horizontal");
        group.setAttribute("size", "small");
        group.append(
            this.createModeOption("visual", "Visual", "html5", "brands"),
            this.createModeOption("source", "Markdown", "markdown", "brands"),
            this.createModeOption("split", "Split", "vr-cardboard"),
        );
        group.addEventListener("change", (): void => {
            const mode = elementValue(group);

            if (isEditorMode(mode) && mode !== this.mode) {
                this.switchMode(mode);
            }
        });

        return group;
    }

    /** Creates one editor view mode radio option. */
    private createModeOption(mode: EditorMode, label: string, iconName: string, iconFamily?: string): HTMLElement {
        const option = document.createElement("wa-radio");
        option.className = "markdown-editor__mode-option";
        option.append(createToolbarIcon(iconName, label, iconFamily));
        option.setAttribute("appearance", "button");
        option.setAttribute("aria-label", label);
        option.setAttribute("title", label);
        option.setAttribute("value", mode);

        return option;
    }

    /** Creates the editor theme radio group. */
    private createThemeGroup(): HTMLElement {
        const group = document.createElement("wa-radio-group");
        group.className = "markdown-editor__theme-group";
        group.setAttribute("aria-label", "Editor colour theme");
        group.setAttribute("orientation", "horizontal");
        group.setAttribute("size", "small");
        group.append(
            this.createThemeOption("light", "Light", "sun"),
            this.createThemeOption("dark", "Dark", "moon"),
            this.createThemeOption("match-system", "Match system", "display"),
        );
        group.addEventListener("change", (): void => {
            const theme = elementValue(group);

            if (isEditorTheme(theme) && theme !== this.theme) {
                this.theme = theme;
                this.updateToolbarState();
            }
        });

        return group;
    }

    /** Creates one editor theme radio option. */
    private createThemeOption(theme: EditorTheme, label: string, iconName: string): HTMLElement {
        const option = document.createElement("wa-radio");
        option.className = "markdown-editor__theme-option";
        option.append(createToolbarIcon(iconName, label));
        option.setAttribute("appearance", "button");
        option.setAttribute("aria-label", label);
        option.setAttribute("title", label);
        option.setAttribute("value", theme);

        return option;
    }

    /** Creates the explicit form submit button for manual saves. */
    private createSaveButton(): ToolbarButtonElement {
        const button = this.createToolbarButton("markdown-editor__save-button", "Save");
        button.setAttribute("appearance", "filled");
        button.setAttribute("type", "submit");
        this.saveButton = button;

        return button;
    }

    /** Creates the save error message shown when the last save failed. */
    private createSaveError(): HTMLSpanElement {
        const error = document.createElement("span");
        error.className = "markdown-editor__save-error";
        error.setAttribute("role", "status");
        error.hidden = true;
        this.saveError = error;

        return error;
    }

    /** Creates the link target editor shown when the Link command is active. */
    private createLinkEditor(): HTMLDivElement {
        const editor = document.createElement("div");
        editor.className = "markdown-editor__link-editor";
        editor.hidden = true;

        const input = document.createElement("input");
        input.className = "markdown-editor__link-target";
        input.placeholder = "Link target";
        input.type = "url";

        const applyButton = this.createToolbarButton("markdown-editor__link-apply", "Apply");
        applyButton.addEventListener("click", (): void => this.applyPendingLinkTarget());

        const cancelButton = this.createToolbarButton("markdown-editor__link-cancel", "Cancel");
        cancelButton.addEventListener("click", (): void => this.hideLinkEditor());

        input.addEventListener("keydown", (event: KeyboardEvent): void => {
            if (event.key === "Enter") {
                event.preventDefault();
                this.applyPendingLinkTarget();
            }

            if (event.key === "Escape") {
                event.preventDefault();
                this.hideLinkEditor();
            }
        });

        editor.append(input, applyButton, cancelButton);
        this.linkEditor = editor;
        this.linkTargetInput = input;

        return editor;
    }

    /** Creates the block style toolbar control. */
    private createStyleDropdown(): HTMLElement {
        const dropdown = document.createElement("wa-dropdown");
        dropdown.className = "markdown-editor__style-dropdown";
        dropdown.setAttribute("aria-label", "Block style");
        dropdown.setAttribute("size", "small");

        this.styleTrigger = this.createToolbarButton("markdown-editor__style-trigger", "Paragraph");
        this.styleTrigger.setAttribute("slot", "trigger");
        this.styleTrigger.setAttribute("with-caret", "");
        dropdown.append(
            this.styleTrigger,
            this.createStyleDropdownItem("paragraph", "Paragraph"),
            this.createStyleDropdownItem("heading-1", "Heading 1"),
            this.createStyleDropdownItem("heading-2", "Heading 2"),
            this.createStyleDropdownItem("heading-3", "Heading 3"),
        );
        dropdown.addEventListener("wa-select", (event: Event): void => {
            const style = elementValue((event as WaDropdownSelectEvent).detail.item as HTMLElement);

            if (isVisualBlockStyle(style)) {
                this.setStyleDropdownValue(style);
                this.applyBlockStyle(style);
            }
        });

        return dropdown;
    }

    /** Creates one item in the block style dropdown control. */
    private createStyleDropdownItem(value: VisualBlockStyle, label: string): HTMLElement {
        const item = document.createElement("wa-dropdown-item");
        item.setAttribute("value", value);
        item.textContent = label;

        return item;
    }

    /** Creates one inline style toolbar button. */
    private createInlineStyleButton(style: VisualInlineStyle, label: string, iconName: string): ToolbarButtonElement {
        const button = this.createToolbarButton("markdown-editor__inline-button", label);
        button.textContent = "";
        button.append(createToolbarIcon(iconName, label));
        button.dataset["inlineStyle"] = style;
        button.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        button.addEventListener("click", (): void => this.toggleInlineStyle(style));
        this.inlineStyleButtons.push(button);

        return button;
    }

    /** Creates one structural style toolbar button. */
    private createStructureButton(style: VisualStructureStyle, label: string, iconName: string): ToolbarButtonElement {
        const button = this.createToolbarButton("markdown-editor__structure-button", label);
        button.textContent = "";
        button.append(createToolbarIcon(iconName, label));
        button.dataset["structureStyle"] = style;
        button.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        button.addEventListener("click", (): void => this.toggleStructure(style));

        return button;
    }

    /** Creates one Web Awesome toolbar command button. */
    private createToolbarButton(className: string, label: string): ToolbarButtonElement {
        const button = document.createElement("wa-button");
        button.className = `markdown-editor__button ${className}`;
        button.textContent = label;
        button.setAttribute("appearance", "outlined");
        button.setAttribute("size", "small");
        button.setAttribute("type", "button");
        button.setAttribute("aria-label", label);
        button.setAttribute("title", label);

        return button;
    }

    /** Creates one Web Awesome toolbar button group. */
    private createToolbarButtonGroup(...buttons: ToolbarButtonElement[]): HTMLElement {
        const group = document.createElement("wa-button-group");
        group.className = "markdown-editor__button-group";
        group.append(...buttons);

        return group;
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

    /** Returns the requested initial colour theme. */
    private editorTheme(): EditorTheme {
        const theme = this.getAttribute("theme");

        if (theme === "light" || theme === "dark" || theme === "match-system") {
            return theme;
        }

        return "match-system";
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
        if (style === "link") {
            this.showLinkEditor();
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

            if (style === "strikethrough") {
                this.sourceEditor?.toggleStrikethrough();
            }

            return;
        }

        if (this.visualEditor?.toggleInlineStyle(style)) {
            this.handleVisualInput();
        }
    }

    /** Shows the link target editor for the current visual or source selection. */
    private showLinkEditor(): void {
        if (!this.linkEditor || !this.linkTargetInput) {
            return;
        }

        this.pendingLink = true;
        this.pendingLinkSourceSelection = this.shouldUseSourceCommands()
            ? (this.sourceEditor?.currentSelection() ?? null)
            : null;
        this.linkTargetInput.value = "";
        this.linkEditor.hidden = false;
        this.positionLinkEditor(selectionClientRect());
        this.linkTargetInput.focus();
        window.setTimeout((): void => {
            if (this.pendingLink) {
                document.addEventListener("pointerdown", this.handleDocumentPointerDown);
            }
        }, 0);
    }

    /** Positions the link editor near the selected text without covering it. */
    private positionLinkEditor(selectionRect: DOMRect | null): void {
        if (!this.linkEditor) {
            return;
        }

        const hostRect = this.getBoundingClientRect();
        const editorRect = this.linkEditor.getBoundingClientRect();
        const anchor = selectionRect ?? this.activeEditPaneRect() ?? this.body?.getBoundingClientRect() ?? hostRect;
        const gap = 8;
        const preferredTop = anchor.bottom - hostRect.top + gap;
        const fallbackTop = anchor.top - hostRect.top - editorRect.height - gap;
        const availableBelow = window.innerHeight - anchor.bottom;
        const top = availableBelow >= editorRect.height + gap ? preferredTop : Math.max(gap, fallbackTop);
        const preferredLeft = anchor.left - hostRect.left;
        const maxLeft = Math.max(gap, hostRect.width - editorRect.width - gap);
        const left = Math.max(gap, Math.min(preferredLeft, maxLeft));

        this.linkEditor.style.left = `${left}px`;
        this.linkEditor.style.top = `${top}px`;
    }

    /** Returns the active edit pane rectangle for overlay anchoring. */
    private activeEditPaneRect(): DOMRect | null {
        if (this.shouldUseSourceCommands()) {
            return this.sourceEditor?.element().getBoundingClientRect() ?? null;
        }

        return this.visualEditor?.element().getBoundingClientRect() ?? null;
    }

    /** Hides the link target editor and discards any pending link command. */
    private hideLinkEditor(): void {
        if (!this.linkEditor || !this.linkTargetInput) {
            return;
        }

        this.pendingLink = false;
        this.pendingLinkSourceSelection = null;
        this.linkTargetInput.value = "";
        this.linkEditor.hidden = true;
        document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
    }

    /** Applies the pending link target to the active editor pane. */
    private applyPendingLinkTarget(): void {
        if (!this.pendingLink || !this.linkTargetInput) {
            return;
        }

        const href = this.linkTargetInput.value.trim();

        if (!href) {
            return;
        }

        const sourceSelection = this.pendingLinkSourceSelection;
        this.hideLinkEditor();

        if (this.shouldUseSourceCommands()) {
            if (sourceSelection) {
                this.sourceEditor?.toggleLinkAt(sourceSelection, href);
            } else {
                this.sourceEditor?.toggleLink(href);
            }
            return;
        }

        if (this.visualEditor?.toggleInlineStyle("link", href)) {
            this.handleVisualInput();
        }
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

            if (style === "code-block") {
                this.sourceEditor?.insertCodeBlock();
            }

            if (style === "thematic-break") {
                this.sourceEditor?.insertThematicBreak();
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
        this.markDirty();
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
            this.lastSubmittedMarkdown = markdown;
        });
        form.addEventListener("htmx:beforeRequest", (): void => {
            this.markSaving();
        });
        form.addEventListener("htmx:afterRequest", (event: Event): void => {
            this.handleSaveResponse(event as HtmxAfterRequestEvent);
        });
        form.addEventListener("htmx:responseError", (): void => {
            this.markRetry("connection error");
        });
        form.addEventListener("htmx:sendError", (): void => {
            this.markRetry("connection error");
        });
        form.addEventListener("htmx:timeout", (): void => {
            this.markRetry("request timed out");
        });
    }

    /** Marks the editor dirty after a local content change. */
    private markDirty(): void {
        if (this.saveState === "saving") {
            return;
        }

        this.clearSaveTransitionTimeout();
        this.hideSaveError();
        this.saveState = "dirty";
        this.updateSaveButton();
    }

    /** Marks the current htmx request as an in-progress save. */
    private markSaving(): void {
        this.clearSaveTimeout();
        this.clearSaveTransitionTimeout();
        this.hideSaveError();
        this.saveStartedAt = Date.now();
        this.saveState = "saving";
        this.updateSaveButton();
        this.saveTimeout = window.setTimeout((): void => {
            if (this.saveState === "saving") {
                this.markRetry("request timed out");
            }
        }, 10_000);
    }

    /** Applies the save state after htmx reports the request outcome. */
    private handleSaveResponse(event: HtmxAfterRequestEvent): void {
        const successful = event.detail.successful ?? isSuccessfulStatus(event.detail.xhr?.status);

        if (!successful) {
            this.markRetry(saveFailureReason(event));
            return;
        }

        const remainingSavingTime = 500 - (Date.now() - this.saveStartedAt);

        if (remainingSavingTime <= 0) {
            this.markSaved();
            return;
        }

        this.clearSaveTransitionTimeout();
        this.saveTransitionTimeout = window.setTimeout((): void => this.markSaved(), remainingSavingTime);
    }

    /** Marks the submitted Markdown as saved after a positive server response. */
    private markSaved(): void {
        this.clearSaveTimeout();
        this.clearSaveTransitionTimeout();
        this.hideSaveError();
        this.saveState = this.toMarkdown() === this.lastSubmittedMarkdown ? "clean" : "dirty";
        this.updateSaveButton();
    }

    /** Marks the last save as failed and allows the user to retry. */
    private markRetry(reason: string): void {
        this.clearSaveTimeout();
        this.clearSaveTransitionTimeout();
        this.saveState = "retry";
        this.showSaveError(`Save failed: ${reason}`);
        this.updateSaveButton();
    }

    /** Clears the outstanding save timeout, if any. */
    private clearSaveTimeout(): void {
        if (this.saveTimeout === null) {
            return;
        }

        window.clearTimeout(this.saveTimeout);
        this.saveTimeout = null;
    }

    /** Clears a delayed save completion transition, if any. */
    private clearSaveTransitionTimeout(): void {
        if (this.saveTransitionTimeout === null) {
            return;
        }

        window.clearTimeout(this.saveTransitionTimeout);
        this.saveTransitionTimeout = null;
    }

    /** Shows a save transport error next to the Save button. */
    private showSaveError(message: string): void {
        if (!this.saveError) {
            return;
        }

        this.saveError.textContent = message;
        this.saveError.hidden = false;
    }

    /** Clears the save transport error. */
    private hideSaveError(): void {
        if (!this.saveError) {
            return;
        }

        this.saveError.textContent = "";
        this.saveError.hidden = true;
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

        if (this.modeGroup) {
            setElementValue(this.modeGroup, this.mode);
            this.modeGroup.setAttribute("value", this.mode);

            for (const option of this.modeGroup.querySelectorAll("wa-radio")) {
                if (option.getAttribute("value") === this.mode) {
                    option.setAttribute("checked", "");
                } else {
                    option.removeAttribute("checked");
                }
            }
        }

        this.setAttribute("data-theme", this.theme);
        this.applyDocumentTheme();

        if (this.themeGroup) {
            setElementValue(this.themeGroup, this.theme);
            this.themeGroup.setAttribute("value", this.theme);

            for (const option of this.themeGroup.querySelectorAll("wa-radio")) {
                if (option.getAttribute("value") === this.theme) {
                    option.setAttribute("checked", "");
                } else {
                    option.removeAttribute("checked");
                }
            }
        }

        if (this.styleTrigger) {
            setToolbarButtonDisabled(this.styleTrigger, !this.visualEditor && !this.sourceEditor);
            this.setStyleDropdownValue("paragraph");
        }

        for (const button of this.inlineStyleButtons) {
            setToolbarButtonDisabled(button, !this.visualEditor && !this.sourceEditor);
        }

        this.updateSaveButton();
    }

    /** Reflects the current save state onto the explicit Save button. */
    private updateSaveButton(): void {
        if (!this.saveButton) {
            return;
        }

        if (this.saveState === "saving") {
            this.saveButton.textContent = "Auto-Saving...";
            setToolbarButtonDisabled(this.saveButton, true);
            return;
        }

        if (this.saveState === "retry") {
            this.saveButton.textContent = "Retry";
            setToolbarButtonDisabled(this.saveButton, false);
            return;
        }

        this.saveButton.textContent = "Save";
        setToolbarButtonDisabled(this.saveButton, this.saveState === "clean");
    }

    /** Applies the editor theme selection to Web Awesome's document-level colour scheme classes. */
    private applyDocumentTheme(): void {
        const root = document.documentElement;
        const theme = this.resolvedEditorTheme();

        root.classList.toggle("wa-light", theme === "light");
        root.classList.toggle("wa-dark", theme === "dark");
    }

    /** Resolves match-system to the current browser colour preference. */
    private resolvedEditorTheme(): "light" | "dark" {
        if (this.theme === "dark") {
            return "dark";
        }

        if (this.theme === "light") {
            return "light";
        }

        return this.systemThemeQuery()?.matches ? "dark" : "light";
    }

    /** Returns the browser colour-scheme media query when available. */
    private systemThemeQuery(): MediaQueryList | null {
        if (typeof window.matchMedia !== "function") {
            return null;
        }

        return window.matchMedia("(prefers-color-scheme: dark)");
    }

    /** Reflects the current block style label into the dropdown trigger. */
    private setStyleDropdownValue(style: VisualBlockStyle): void {
        if (!this.styleDropdown || !this.styleTrigger) {
            return;
        }

        this.styleTrigger.textContent = blockStyleLabel(style);

        for (const item of this.styleDropdown.querySelectorAll("wa-dropdown-item")) {
            if (item.getAttribute("value") === style) {
                item.setAttribute("checked", "");
            } else {
                item.removeAttribute("checked");
            }
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

/** Returns the toolbar label for a supported block style. */
function blockStyleLabel(style: VisualBlockStyle): string {
    if (style === "heading-1") {
        return "Heading 1";
    }

    if (style === "heading-2") {
        return "Heading 2";
    }

    if (style === "heading-3") {
        return "Heading 3";
    }

    return "Paragraph";
}

/** Checks whether a value is an editor mode. */
function isEditorMode(mode: string): mode is EditorMode {
    return mode === "visual" || mode === "source" || mode === "split";
}

/** Checks whether a value is an editor colour theme. */
function isEditorTheme(theme: string): theme is EditorTheme {
    return theme === "light" || theme === "dark" || theme === "match-system";
}

/** Checks whether an HTTP status code should be treated as a successful save. */
function isSuccessfulStatus(status: number | undefined): boolean {
    return typeof status === "number" && status >= 200 && status < 300;
}

/** Returns a concise user-facing save failure reason from an htmx response event. */
function saveFailureReason(event: HtmxAfterRequestEvent): string {
    const status = event.detail.xhr?.status;

    if (typeof status === "number" && status > 0) {
        return `HTTP ${status}`;
    }

    return "connection error";
}

/** Returns the current non-empty selection rectangle, if the browser can provide one. */
function selectionClientRect(): DOMRect | null {
    const selection = window.getSelection();

    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
        return null;
    }

    const range = selection.getRangeAt(0);
    const rect = firstUsableClientRect(range.getClientRects());

    return rect ?? range.getBoundingClientRect();
}

/** Finds the first selection rectangle with useful dimensions. */
function firstUsableClientRect(rects: DOMRectList): DOMRect | null {
    for (const rect of rects) {
        if (rect.width > 0 && rect.height > 0) {
            return rect;
        }
    }

    return null;
}

/** Reads the string value from an HTML or custom form control host. */
function elementValue(element: HTMLElement): string {
    const value = (element as HTMLElement & { value?: unknown }).value;

    if (typeof value === "string") {
        return value;
    }

    return element.getAttribute("value") ?? "";
}

/** Sets the string value on an HTML or custom form control host. */
function setElementValue(element: HTMLElement, value: string): void {
    (element as HTMLElement & { value?: string }).value = value;
}

/** Creates an icon for one toolbar command. */
function createToolbarIcon(name: string, label: string, family?: string): HTMLElement {
    const icon = document.createElement("wa-icon");
    icon.className = "markdown-editor__button-icon";
    icon.setAttribute("name", name);
    icon.setAttribute("variant", "solid");
    icon.setAttribute("label", label);

    if (family) {
        icon.setAttribute("family", family);
    }

    return icon;
}

/** Reflects disabled state onto custom toolbar command elements. */
function setToolbarButtonDisabled(button: ToolbarButtonElement, disabled: boolean): void {
    if (disabled) {
        button.setAttribute("disabled", "");
        return;
    }

    button.removeAttribute("disabled");
}
