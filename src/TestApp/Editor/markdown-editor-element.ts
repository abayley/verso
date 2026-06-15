import { CodeMirrorSourceEditor, type CodeMirrorSourceSelection } from "./codemirror-source-editor.js";
import { renderMarkdown } from "./markdown-render.js";
import {
    TiptapVisualEditor,
    type VisualBlockStyle,
    type VisualInlineStyle,
    type VisualLinkSelection,
    type VisualStructureStyle,
} from "./tiptap-visual-editor.js";

type EditorMode = "visual" | "source" | "split";
type EditorTheme = "light" | "dark" | "match-system";
type VisualTheme = "paper" | "aurora" | "blueprint" | "herbarium" | "workbench" | "studio";
type ActivePane = "source" | "visual";
type SaveState = "clean" | "dirty" | "saving" | "retry";
type ToolbarButtonElement = HTMLElement;

const linkActionsHideDelayMilliseconds = 500;
const toolbarTooltipHideDelayMilliseconds = 250;
const toolbarTooltipShowDelayMilliseconds = 500;

const visualThemeStorageKey = "editor-theme";
const colorSchemeStorageKey = "editor-color-scheme";

/** The selectable visual themes, in dropdown order; the first is the default. */
const visualThemes: { value: VisualTheme; label: string }[] = [
    { value: "paper", label: "Paper" },
    { value: "aurora", label: "Aurora" },
    { value: "blueprint", label: "Blueprint" },
    { value: "herbarium", label: "Herbarium" },
    { value: "workbench", label: "Workbench" },
    { value: "studio", label: "Studio" },
];

let tooltipTargetSequence = 0;

/** Narrows an arbitrary string to a known visual theme. */
function isVisualTheme(value: string | null): value is VisualTheme {
    return value !== null && visualThemes.some((theme) => theme.value === value);
}

/** The display label for a visual theme. */
function themeLabel(theme: VisualTheme): string {
    return visualThemes.find((entry) => entry.value === theme)?.label ?? theme;
}

/** A theme's default view mode (a preset applied when no mode is requested), or null. */
function themeDefaultMode(theme: VisualTheme): EditorMode | null {
    return theme === "workbench" ? "split" : null;
}

/** Whether a theme replaces the persistent command bar with the bubble toolbar and slash menu. */
function themeUsesStudioSurfaces(theme: VisualTheme): boolean {
    return theme === "studio";
}

/** Reads a stored preference, tolerating an unavailable or throwing localStorage. */
function readStoredPreference(key: string): string | null {
    try {
        return window.localStorage.getItem(key);
    } catch {
        return null;
    }
}

/** Writes a stored preference, ignoring an unavailable or throwing localStorage. */
function writeStoredPreference(key: string, value: string): void {
    try {
        window.localStorage.setItem(key, value);
    } catch {
        // A preference that cannot be persisted is non-fatal; the session keeps it.
    }
}

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
    private activeVisualLinkRect: DOMRect | null = null;
    private activeVisualLinkSelection: VisualLinkSelection | null = null;
    private linkActionsHideTimeout: number | null = null;
    private linkActions: HTMLDivElement | null = null;
    private linkEditor: HTMLDivElement | null = null;
    private linkTargetInput: HTMLInputElement | null = null;
    private lastSubmittedMarkdown = "";
    private pendingLink = false;
    private pendingLinkSourceSelection: CodeMirrorSourceSelection | null = null;
    private pendingVisualLinkSelection: VisualLinkSelection | null = null;
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
    private themeDropdown: HTMLElement | null = null;
    private themeDropdownTrigger: ToolbarButtonElement | null = null;
    private visualTheme: VisualTheme = "paper";
    private toolbarTooltip: HTMLElement | null = null;
    private toolbarTooltipHideTimeout: number | null = null;
    private toolbarTooltipShowTimeout: number | null = null;
    private readonly handleSystemThemeChange = (): void => {
        if (this.theme === "match-system") {
            this.applyDocumentTheme();
        }
    };
    private readonly handleDocumentPointerDown = (event: PointerEvent): void => {
        if (!this.pendingLink && !this.isLinkActionsVisible()) {
            return;
        }

        const target = event.target;

        if (target instanceof Node && this.linkEditor?.contains(target)) {
            return;
        }

        if (target instanceof Node && this.linkActions?.contains(target)) {
            return;
        }

        if (this.pendingLink) {
            this.hideLinkEditor();
        }

        if (this.isLinkActionsVisible()) {
            this.hideLinkActions();
        }
    };
    private readonly handleDocumentPointerOver = (event: PointerEvent): void => {
        const target = event.target;

        if (!(target instanceof Element) || !this.visualEditor) {
            this.scheduleLinkActionsHide();
            return;
        }

        if (this.linkActions?.contains(target)) {
            this.cancelLinkActionsHide();
            return;
        }

        const anchor = target.closest("a");

        if (anchor instanceof HTMLAnchorElement && this.visualEditor.element().contains(anchor)) {
            this.cancelLinkActionsHide();
            return;
        }

        this.scheduleLinkActionsHide();
    };
    private readonly handleVisualPointerOver = (event: PointerEvent): void => {
        const target = event.target;

        if (!(target instanceof Element) || !this.visualEditor) {
            return;
        }

        const anchor = target.closest("a");

        if (!(anchor instanceof HTMLAnchorElement) || !this.visualEditor.element().contains(anchor)) {
            this.scheduleLinkActionsHide();
            return;
        }

        const selection = this.visualEditor.linkSelectionFromAnchor(anchor);

        if (!selection) {
            this.hideLinkActions();
            return;
        }

        this.showLinkActions(selection, anchor.getBoundingClientRect());
    };
    private readonly handleSelectionChange = (): void => {
        this.updateBubbleToolbar();
        this.updateSlashMenu();
    };
    private readonly handleSlashKeydown = (event: KeyboardEvent): void => {
        if (!this.slashMenu || this.slashMenu.hidden) {
            return;
        }

        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            event.stopPropagation();
            const delta = event.key === "ArrowDown" ? 1 : -1;
            this.slashIndex = (this.slashIndex + delta + this.slashItems.length) % this.slashItems.length;
            this.highlightSlashItem();
        } else if (event.key === "Enter") {
            event.preventDefault();
            event.stopPropagation();
            this.slashItems[this.slashIndex]?.run();
        } else if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            this.closeSlashMenu();
        }
    };
    private bubbleToolbar: HTMLDivElement | null = null;
    private bubbleStyleTrigger: ToolbarButtonElement | null = null;
    private readonly bubbleStyleButtons: { style: VisualInlineStyle; button: ToolbarButtonElement }[] = [];
    private slashMenu: HTMLDivElement | null = null;
    private readonly slashItems: { button: ToolbarButtonElement; run: () => void }[] = [];
    private slashIndex = 0;
    private commandBar: HTMLDivElement | null = null;
    private documentName: HTMLSpanElement | null = null;
    private toolbar: HTMLDivElement | null = null;
    private visualEditor: TiptapVisualEditor | null = null;
    private visualEditorChanged = false;
    private wordCount: HTMLSpanElement | null = null;

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
        document.removeEventListener("pointerover", this.handleDocumentPointerOver);
        document.removeEventListener("selectionchange", this.handleSelectionChange);
        this.closeSlashMenu();
        this.cancelLinkActionsHide();
        this.hideToolbarTooltip();
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
        this.visualTheme = this.editorVisualTheme();
        this.theme = this.editorTheme();
        this.mode = this.editorMode();
        this.textContent = "";

        this.toolbarTooltip = this.createToolbarTooltip();
        this.toolbar = this.createToolbar();
        this.commandBar = this.createCommandBar();
        this.linkEditor = this.createLinkEditor();
        this.linkActions = this.createLinkActions();
        this.bubbleToolbar = this.createBubbleToolbar();
        this.slashMenu = this.createSlashMenu();
        this.body = document.createElement("div");
        this.body.className = "markdown-editor__body";
        this.parseError = document.createElement("div");
        this.parseError.className = "markdown-editor__error";
        this.parseError.setAttribute("role", "alert");
        this.parseError.hidden = true;
        this.wordCount = document.createElement("span");
        this.wordCount.className = "markdown-editor__word-count";

        const notices = document.createElement("div");
        notices.className = "markdown-editor__notices";
        notices.append(this.parseError, this.createSaveError());

        const footer = document.createElement("div");
        footer.className = "markdown-editor__footer";
        footer.append(notices, this.commandBar);

        this.append(
            this.toolbar,
            this.linkEditor,
            this.linkActions,
            this.bubbleToolbar,
            this.slashMenu,
            this.toolbarTooltip,
            this.body,
            footer,
            this.wordCount,
        );
        this.renderMode();
        this.updateToolbarState();
        this.updatePreview();
        this.updateWordCount();
        this.configureFormSubmission();
        this.systemThemeQuery()?.addEventListener("change", this.handleSystemThemeChange);
        document.addEventListener("selectionchange", this.handleSelectionChange);
    }

    /** Creates the top editor bar with the document name and view controls. */
    private createToolbar(): HTMLDivElement {
        const toolbar = document.createElement("div");
        toolbar.className = "markdown-editor__toolbar markdown-editor__toolbar--top";
        this.documentName = this.createDocumentName();
        toolbar.append(this.documentName);
        this.modeGroup = this.createModeGroup();
        toolbar.append(this.modeGroup);
        this.themeDropdown = this.createThemeDropdown();
        toolbar.append(this.themeDropdown);
        this.themeGroup = this.createThemeGroup();
        toolbar.append(this.themeGroup);

        return toolbar;
    }

    /** Creates the floating command bar with formatting and save controls. */
    private createCommandBar(): HTMLDivElement {
        const bar = document.createElement("div");
        bar.className = "markdown-editor__toolbar markdown-editor__toolbar--commands";
        bar.setAttribute("role", "toolbar");
        this.styleDropdown = this.createStyleDropdown();
        bar.append(this.styleDropdown);
        bar.append(
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
        bar.append(this.createSaveButton());

        return bar;
    }

    /** Creates the document name label shown in the editor top bar. */
    private createDocumentName(): HTMLSpanElement {
        const name = document.createElement("span");
        name.className = "markdown-editor__document-name";
        const fileName = documentFileName(this.getAttribute("src"));
        name.textContent = fileName ?? "";
        name.hidden = fileName === null;

        return name;
    }

    /** Creates the editor view mode radio group. */
    private createModeGroup(): HTMLElement {
        const group = document.createElement("wa-radio-group");
        group.className = "markdown-editor__mode-group";
        group.setAttribute("aria-label", "Editor view mode");
        group.setAttribute("orientation", "horizontal");
        group.setAttribute("size", "small");
        group.append(
            this.createModeOption("visual", "Visual"),
            this.createModeOption("source", "Markdown"),
            this.createModeOption("split", "Split"),
        );
        group.addEventListener("change", (): void => {
            const mode = elementValue(group);

            if (isEditorMode(mode) && mode !== this.mode) {
                this.switchMode(mode);
            }
        });

        return group;
    }

    /** Creates one editor view mode radio option with a text label. */
    private createModeOption(mode: EditorMode, label: string): HTMLElement {
        const option = document.createElement("wa-radio");
        option.className = "markdown-editor__mode-option";
        option.textContent = label;
        option.setAttribute("appearance", "button");
        option.setAttribute("aria-label", label);
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
                writeStoredPreference(colorSchemeStorageKey, theme);
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
        option.setAttribute("value", theme);
        this.addTooltip(option, label);

        return option;
    }

    /** Creates the visual-theme dropdown shown in the top bar. */
    private createThemeDropdown(): HTMLElement {
        const dropdown = document.createElement("wa-dropdown");
        dropdown.className = "markdown-editor__theme-dropdown";
        dropdown.setAttribute("aria-label", "Visual theme");
        dropdown.setAttribute("size", "small");

        this.themeDropdownTrigger = this.createToolbarButton(
            "markdown-editor__theme-trigger",
            themeLabel(this.visualTheme),
        );
        this.themeDropdownTrigger.setAttribute("slot", "trigger");
        this.themeDropdownTrigger.setAttribute("with-caret", "");
        dropdown.append(this.themeDropdownTrigger);

        for (const theme of visualThemes) {
            dropdown.append(this.createThemeDropdownItem(theme.value, theme.label));
        }

        dropdown.addEventListener("wa-select", (event: Event): void => {
            const value = elementValue((event as WaDropdownSelectEvent).detail.item as HTMLElement);

            if (isVisualTheme(value)) {
                this.setVisualTheme(value);
            }
        });

        return dropdown;
    }

    /** Creates one item in the visual-theme dropdown. */
    private createThemeDropdownItem(value: VisualTheme, label: string): HTMLElement {
        const item = document.createElement("wa-dropdown-item");
        item.setAttribute("value", value);
        item.textContent = label;

        return item;
    }

    /** Applies, persists, and reflects a chosen visual theme. */
    private setVisualTheme(theme: VisualTheme): void {
        this.visualTheme = theme;
        writeStoredPreference(visualThemeStorageKey, theme);
        this.applyVisualTheme();
        this.syncThemeDropdown();
    }

    /** Sets the document's visual-theme attribute and reflects Studio's chrome. */
    private applyVisualTheme(): void {
        document.documentElement.setAttribute("data-editor-theme", this.visualTheme);
        // The bubble toolbar and slash menu are visual-pane only, so the command
        // bar is suppressed only in visual mode; source and split keep it usable.
        const surfacesActive = themeUsesStudioSurfaces(this.visualTheme) && this.mode === "visual";
        this.classList.toggle("markdown-editor--studio-surfaces", surfacesActive);
        this.updateBubbleToolbar();
    }

    /** Resolves the initial visual theme: stored preference, then page attribute, else paper. */
    private editorVisualTheme(): VisualTheme {
        const stored = readStoredPreference(visualThemeStorageKey);

        if (isVisualTheme(stored)) {
            return stored;
        }

        const fromPage = document.documentElement.getAttribute("data-editor-theme");

        return isVisualTheme(fromPage) ? fromPage : "paper";
    }

    /** Reflects the current visual theme into the dropdown trigger and items. */
    private syncThemeDropdown(): void {
        if (this.themeDropdownTrigger) {
            this.themeDropdownTrigger.textContent = themeLabel(this.visualTheme);
        }

        if (!this.themeDropdown) {
            return;
        }

        for (const item of this.themeDropdown.querySelectorAll("wa-dropdown-item")) {
            if (item.getAttribute("value") === this.visualTheme) {
                item.setAttribute("checked", "");
            } else {
                item.removeAttribute("checked");
            }
        }
    }

    /** Creates the explicit form submit button for manual saves. */
    private createSaveButton(): ToolbarButtonElement {
        const button = this.createToolbarButton("markdown-editor__save-button", "Save");
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

    /** Creates the existing-link hover actions. */
    private createLinkActions(): HTMLDivElement {
        const actions = document.createElement("div");
        actions.className = "markdown-editor__link-actions";
        actions.hidden = true;

        const editButton = this.createToolbarButton("markdown-editor__link-edit", "Edit link");
        editButton.textContent = "";
        editButton.append(createToolbarIcon("pencil", "Edit link"));
        editButton.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        editButton.addEventListener("click", (): void => this.editActiveVisualLink());

        const removeButton = this.createToolbarButton("markdown-editor__link-remove", "Remove link");
        removeButton.textContent = "";
        removeButton.append(createToolbarIcon("link-slash", "Remove link"));
        removeButton.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        removeButton.addEventListener("click", (): void => this.removeActiveVisualLink());
        actions.addEventListener("pointerover", (): void => this.cancelLinkActionsHide());

        actions.append(editButton, removeButton);
        this.linkActions = actions;

        return actions;
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
        const button = this.createToolbarButton("markdown-editor__inline-button", label, shortcutForInlineStyle(style));
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

    /** Creates the Studio selection bubble toolbar with the inline command buttons. */
    private createBubbleToolbar(): HTMLDivElement {
        const bubble = document.createElement("div");
        bubble.className = "markdown-editor__bubble";
        bubble.setAttribute("role", "toolbar");
        bubble.hidden = true;
        bubble.append(
            this.createBubbleStyleDropdown(),
            this.createBubbleButton("strong", "Bold", "bold"),
            this.createBubbleButton("emphasis", "Italic", "italic"),
            this.createBubbleButton("strikethrough", "Strike", "strikethrough"),
            this.createBubbleButton("code", "Code", "code"),
            this.createBubbleButton("link", "Link", "link"),
        );

        return bubble;
    }

    /** Creates the bubble's block-style selector, reusing the command bar's block command path. */
    private createBubbleStyleDropdown(): HTMLElement {
        const dropdown = document.createElement("wa-dropdown");
        dropdown.className = "markdown-editor__bubble-style";
        dropdown.setAttribute("aria-label", "Block style");
        dropdown.setAttribute("size", "small");

        this.bubbleStyleTrigger = this.createToolbarButton("markdown-editor__bubble-style-trigger", "Paragraph");
        this.bubbleStyleTrigger.setAttribute("slot", "trigger");
        this.bubbleStyleTrigger.setAttribute("with-caret", "");
        dropdown.append(
            this.bubbleStyleTrigger,
            this.createStyleDropdownItem("paragraph", "Paragraph"),
            this.createStyleDropdownItem("heading-1", "Heading 1"),
            this.createStyleDropdownItem("heading-2", "Heading 2"),
            this.createStyleDropdownItem("heading-3", "Heading 3"),
        );
        dropdown.addEventListener("wa-select", (event: Event): void => {
            const style = elementValue((event as WaDropdownSelectEvent).detail.item as HTMLElement);

            if (isVisualBlockStyle(style)) {
                this.applyBlockStyle(style);
                this.updateBubbleToolbar();
            }
        });

        return dropdown;
    }

    /** Creates one bubble toolbar button, reusing the existing inline command path. */
    private createBubbleButton(style: VisualInlineStyle, label: string, iconName: string): ToolbarButtonElement {
        const button = this.createToolbarButton("markdown-editor__bubble-button", label, shortcutForInlineStyle(style));
        button.textContent = "";
        button.append(createToolbarIcon(iconName, label));
        button.dataset["inlineStyle"] = style;
        button.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        button.addEventListener("click", (): void => {
            this.toggleInlineStyle(style);
            this.updateBubbleToolbar();
        });
        this.bubbleStyleButtons.push({ button, style });

        return button;
    }

    /** Shows or hides the bubble toolbar over the current visual selection under Studio. */
    private updateBubbleToolbar(): void {
        if (!this.bubbleToolbar) {
            return;
        }

        if (!themeUsesStudioSurfaces(this.visualTheme) || !this.visualEditor) {
            this.hideBubbleToolbar();
            return;
        }

        const range = visualSelectionRange(this.visualEditor.element());

        if (!range) {
            this.hideBubbleToolbar();
            return;
        }

        this.bubbleToolbar.hidden = false;
        this.positionOverlay(this.bubbleToolbar, range.getBoundingClientRect());

        if (this.bubbleStyleTrigger) {
            this.bubbleStyleTrigger.textContent = blockStyleLabel(this.visualEditor.currentBlockStyle());
        }

        for (const { button, style } of this.bubbleStyleButtons) {
            button.classList.toggle("markdown-editor__bubble-button--active", this.visualEditor.isInlineActive(style));
        }
    }

    /** Hides the bubble toolbar. */
    private hideBubbleToolbar(): void {
        if (this.bubbleToolbar) {
            this.bubbleToolbar.hidden = true;
        }
    }

    /** Creates the Studio slash command menu, reusing the existing block and structure commands. */
    private createSlashMenu(): HTMLDivElement {
        const menu = document.createElement("div");
        menu.className = "markdown-editor__slash-menu";
        menu.setAttribute("role", "listbox");
        menu.hidden = true;

        const commands: { label: string; run: () => void }[] = [
            { label: "Heading 1", run: (): void => this.applyBlockStyle("heading-1") },
            { label: "Heading 2", run: (): void => this.applyBlockStyle("heading-2") },
            { label: "Heading 3", run: (): void => this.applyBlockStyle("heading-3") },
            { label: "Bullet list", run: (): void => this.toggleStructure("bullet-list") },
            { label: "Numbered list", run: (): void => this.toggleStructure("ordered-list") },
            { label: "Quote", run: (): void => this.toggleStructure("blockquote") },
            { label: "Code block", run: (): void => this.toggleStructure("code-block") },
        ];

        for (const command of commands) {
            const item = document.createElement("button");
            item.type = "button";
            item.className = "markdown-editor__slash-item";
            item.textContent = command.label;
            item.addEventListener("mousedown", (event: MouseEvent): void => {
                event.preventDefault();
            });
            item.addEventListener("click", (): void => this.runSlashCommand(command.run));
            menu.append(item);
            this.slashItems.push({ button: item, run: (): void => this.runSlashCommand(command.run) });
        }

        return menu;
    }

    /** Shows or hides the slash menu at the caret when the current block is a slash trigger under Studio. */
    private updateSlashMenu(): void {
        if (!this.slashMenu) {
            return;
        }

        if (!themeUsesStudioSurfaces(this.visualTheme) || !this.visualEditor?.isSlashTrigger()) {
            this.closeSlashMenu();
            return;
        }

        if (this.slashMenu.hidden) {
            this.slashIndex = 0;
            this.addEventListener("keydown", this.handleSlashKeydown, true);
        }

        this.slashMenu.hidden = false;
        const caret = this.visualEditor.slashCaretRect() ?? this.activeEditPaneRect();

        if (caret) {
            this.positionOverlay(this.slashMenu, caret);
        }

        this.highlightSlashItem();
    }

    /** Hides the slash menu and removes its keyboard navigation. */
    private closeSlashMenu(): void {
        this.removeEventListener("keydown", this.handleSlashKeydown, true);

        if (this.slashMenu) {
            this.slashMenu.hidden = true;
        }

        this.slashIndex = 0;
    }

    /** Reflects the highlighted slash command onto the menu items. */
    private highlightSlashItem(): void {
        this.slashItems.forEach(({ button }, index): void => {
            button.classList.toggle("markdown-editor__slash-item--active", index === this.slashIndex);
        });
    }

    /** Removes the slash trigger and applies the chosen command. */
    private runSlashCommand(apply: () => void): void {
        this.visualEditor?.deleteSlashTrigger();
        apply();
        this.closeSlashMenu();
    }

    /** Creates one Web Awesome toolbar command button. */
    private createToolbarButton(
        className: string,
        label: string,
        shortcut: string | null = null,
    ): ToolbarButtonElement {
        const button = document.createElement("wa-button");
        button.className = `markdown-editor__button ${className}`;
        button.textContent = label;
        button.setAttribute("appearance", "plain");
        button.setAttribute("size", "small");
        button.setAttribute("type", "button");
        button.setAttribute("aria-label", label);
        this.addTooltip(button, label, shortcut);

        return button;
    }

    /** Registers a Web Awesome tooltip for one editor control. */
    private addTooltip(target: HTMLElement, label: string, shortcut: string | null = null): void {
        const tooltipId = `markdown-editor-control-${++tooltipTargetSequence}`;
        const tooltipText = shortcut ? `${label} (${shortcut})` : label;

        target.id = target.id || tooltipId;
        target.dataset["tooltipText"] = tooltipText;
        target.addEventListener("pointerover", (): void => this.showToolbarTooltip(target));
        target.addEventListener("focusin", (): void => this.showToolbarTooltip(target));
        target.addEventListener("pointerout", (): void => this.scheduleToolbarTooltipHide());
        target.addEventListener("focusout", (): void => this.scheduleToolbarTooltipHide());
    }

    /** Creates the shared toolbar tooltip. */
    private createToolbarTooltip(): HTMLElement {
        const tooltip = document.createElement("wa-tooltip");
        tooltip.className = "markdown-editor__tooltip";
        tooltip.setAttribute("trigger", "manual");

        return tooltip;
    }

    /** Shows or schedules the shared toolbar tooltip for a target control. */
    private showToolbarTooltip(target: HTMLElement): void {
        const tooltipText = target.dataset["tooltipText"];

        if (!tooltipText) {
            return;
        }

        const warmTooltip = this.isToolbarTooltipVisible() || this.toolbarTooltipHideTimeout !== null;

        this.cancelToolbarTooltipHide();
        this.cancelToolbarTooltipShow();

        if (warmTooltip) {
            this.openToolbarTooltip(target, tooltipText);
            return;
        }

        this.toolbarTooltipShowTimeout = window.setTimeout((): void => {
            this.toolbarTooltipShowTimeout = null;
            this.openToolbarTooltip(target, tooltipText);
        }, toolbarTooltipShowDelayMilliseconds);
    }

    /** Opens the shared toolbar tooltip on a target control. */
    private openToolbarTooltip(target: HTMLElement, tooltipText: string): void {
        if (!this.toolbarTooltip) {
            return;
        }

        this.toolbarTooltip.setAttribute("for", target.id);
        this.toolbarTooltip.textContent = tooltipText;
        this.toolbarTooltip.setAttribute("open", "");
    }

    /** Hides the shared toolbar tooltip after a short grace period. */
    private scheduleToolbarTooltipHide(): void {
        this.cancelToolbarTooltipShow();

        if (!this.isToolbarTooltipVisible() || this.toolbarTooltipHideTimeout !== null) {
            return;
        }

        this.toolbarTooltipHideTimeout = window.setTimeout((): void => {
            this.toolbarTooltipHideTimeout = null;
            this.hideToolbarTooltip();
        }, toolbarTooltipHideDelayMilliseconds);
    }

    /** Hides the shared toolbar tooltip immediately. */
    private hideToolbarTooltip(): void {
        this.cancelToolbarTooltipShow();
        this.cancelToolbarTooltipHide();
        this.toolbarTooltip?.removeAttribute("open");
    }

    /** Cancels a pending toolbar tooltip show timer. */
    private cancelToolbarTooltipShow(): void {
        if (this.toolbarTooltipShowTimeout === null) {
            return;
        }

        window.clearTimeout(this.toolbarTooltipShowTimeout);
        this.toolbarTooltipShowTimeout = null;
    }

    /** Cancels a pending toolbar tooltip hide timer. */
    private cancelToolbarTooltipHide(): void {
        if (this.toolbarTooltipHideTimeout === null) {
            return;
        }

        window.clearTimeout(this.toolbarTooltipHideTimeout);
        this.toolbarTooltipHideTimeout = null;
    }

    /** Checks whether the shared toolbar tooltip is currently open. */
    private isToolbarTooltipVisible(): boolean {
        return Boolean(this.toolbarTooltip?.hasAttribute("open"));
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
        this.visualEditorChanged = false;
        this.panes = null;
        this.body.textContent = "";

        if (this.mode === "source" || this.mode === "split") {
            this.sourceEditor = new CodeMirrorSourceEditor(
                this.markdown,
                (): void => this.handleSourceInput(),
                (): void => this.handleSourceLinkShortcut(),
            );
            this.sourceEditor.element().addEventListener("focusin", (): void => {
                this.activePane = "source";
            });
        }

        if (this.mode === "visual" || this.mode === "split") {
            this.visualEditor = new TiptapVisualEditor(
                this.markdown,
                (): void => this.handleVisualInput(),
                (): void => this.handleVisualLinkShortcut(),
            );
            this.visualEditor.element().addEventListener("focusin", (): void => {
                this.activePane = "visual";
            });
            this.visualEditor.element().addEventListener("pointerover", this.handleVisualPointerOver);
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

        if (mode === "source" || mode === "split" || mode === "visual") {
            return mode;
        }

        return themeDefaultMode(this.visualTheme) ?? "visual";
    }

    /** Returns the initial colour scheme: stored preference, then attribute, else match-system. */
    private editorTheme(): EditorTheme {
        const stored = readStoredPreference(colorSchemeStorageKey);

        if (stored !== null && isEditorTheme(stored)) {
            return stored;
        }

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

        if (!this.visualEditorChanged) {
            return this.markdown;
        }

        return this.visualEditor.toMarkdown();
    }

    /** Replaces the current Markdown document and refreshes the active editor. */
    public setMarkdown(markdown: string): void {
        this.markdown = markdown;
        this.visualEditorChanged = false;

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
    private showLinkEditor(
        href = "",
        visualLinkSelection: VisualLinkSelection | null = null,
        anchorRect: DOMRect | null = null,
    ): void {
        if (!this.linkEditor || !this.linkTargetInput) {
            return;
        }

        this.hideLinkActions();
        this.pendingLink = true;
        this.pendingLinkSourceSelection = this.shouldUseSourceCommands()
            ? (this.sourceEditor?.currentSelection() ?? null)
            : null;
        this.pendingVisualLinkSelection = visualLinkSelection;
        this.linkTargetInput.value = href;
        this.linkEditor.hidden = false;
        this.positionLinkEditor(anchorRect ?? selectionClientRect());
        this.linkTargetInput.focus();
        window.setTimeout((): void => {
            if (this.pendingLink) {
                document.addEventListener("pointerdown", this.handleDocumentPointerDown);
            }
        }, 0);
    }

    /** Opens link editing from a source-pane keyboard shortcut. */
    private handleSourceLinkShortcut(): void {
        this.activePane = "source";
        this.showLinkEditor();
    }

    /** Opens link editing from a visual-pane keyboard shortcut. */
    private handleVisualLinkShortcut(): void {
        this.activePane = "visual";
        this.showLinkEditor();
    }

    /** Positions the link editor near the selected text without covering it. */
    private positionLinkEditor(selectionRect: DOMRect | null): void {
        if (!this.linkEditor) {
            return;
        }

        const anchor =
            selectionRect ??
            this.activeEditPaneRect() ??
            this.body?.getBoundingClientRect() ??
            this.getBoundingClientRect();

        this.positionOverlay(this.linkEditor, anchor);
    }

    /** Positions an editor overlay near an anchor without covering it. */
    private positionOverlay(overlay: HTMLElement, anchor: DOMRect): void {
        const hostRect = this.getBoundingClientRect();
        const overlayRect = overlay.getBoundingClientRect();
        const gap = 8;
        const preferredTop = anchor.bottom - hostRect.top + gap;
        const fallbackTop = anchor.top - hostRect.top - overlayRect.height - gap;
        const availableBelow = window.innerHeight - anchor.bottom;
        const top = availableBelow >= overlayRect.height + gap ? preferredTop : Math.max(gap, fallbackTop);
        const preferredLeft = anchor.left - hostRect.left;
        const maxLeft = Math.max(gap, hostRect.width - overlayRect.width - gap);
        const left = Math.max(gap, Math.min(preferredLeft, maxLeft));

        overlay.style.left = `${left}px`;
        overlay.style.top = `${top}px`;
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
        this.pendingVisualLinkSelection = null;
        this.linkTargetInput.value = "";
        this.linkEditor.hidden = true;

        if (!this.isLinkActionsVisible()) {
            document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
        }
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
        const visualLinkSelection = this.pendingVisualLinkSelection;
        this.hideLinkEditor();

        if (this.shouldUseSourceCommands()) {
            if (sourceSelection) {
                this.sourceEditor?.toggleLinkAt(sourceSelection, href);
            } else {
                this.sourceEditor?.toggleLink(href);
            }
            return;
        }

        if (visualLinkSelection) {
            if (this.visualEditor?.setLinkAt(visualLinkSelection, href)) {
                this.handleVisualInput();
            }
            return;
        }

        if (this.visualEditor?.toggleInlineStyle("link", href)) {
            this.handleVisualInput();
        }
    }

    /** Shows existing-link hover actions near a rendered link. */
    private showLinkActions(selection: VisualLinkSelection, anchorRect: DOMRect): void {
        if (!this.linkActions || this.pendingLink) {
            return;
        }

        this.activeVisualLinkRect = anchorRect;
        this.activeVisualLinkSelection = selection;
        this.cancelLinkActionsHide();
        this.linkActions.hidden = false;
        this.positionOverlay(this.linkActions, anchorRect);
        document.addEventListener("pointerdown", this.handleDocumentPointerDown);
        document.addEventListener("pointerover", this.handleDocumentPointerOver);
    }

    /** Hides existing-link hover actions. */
    private hideLinkActions(): void {
        if (!this.linkActions) {
            return;
        }

        this.activeVisualLinkSelection = null;
        this.activeVisualLinkRect = null;
        this.cancelLinkActionsHide();
        this.linkActions.hidden = true;
        document.removeEventListener("pointerover", this.handleDocumentPointerOver);

        if (!this.pendingLink) {
            document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
        }
    }

    /** Starts the delayed hide timer for existing-link actions. */
    private scheduleLinkActionsHide(): void {
        if (!this.isLinkActionsVisible() || this.linkActionsHideTimeout !== null) {
            return;
        }

        this.linkActionsHideTimeout = window.setTimeout((): void => {
            this.linkActionsHideTimeout = null;
            this.hideLinkActions();
        }, linkActionsHideDelayMilliseconds);
    }

    /** Cancels the delayed hide timer for existing-link actions. */
    private cancelLinkActionsHide(): void {
        if (this.linkActionsHideTimeout === null) {
            return;
        }

        window.clearTimeout(this.linkActionsHideTimeout);
        this.linkActionsHideTimeout = null;
    }

    /** Checks whether existing-link hover actions are visible. */
    private isLinkActionsVisible(): boolean {
        return Boolean(this.linkActions && !this.linkActions.hidden);
    }

    /** Opens the link target editor for the active rendered link. */
    private editActiveVisualLink(): void {
        const selection = this.activeVisualLinkSelection;

        if (!selection) {
            return;
        }

        this.showLinkEditor(selection.href, selection, this.activeVisualLinkRect);
    }

    /** Removes the link mark from the active rendered link while keeping its text. */
    private removeActiveVisualLink(): void {
        const selection = this.activeVisualLinkSelection;

        if (!selection) {
            return;
        }

        this.hideLinkActions();

        if (this.visualEditor?.unsetLinkAt(selection)) {
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

        this.visualEditorChanged = true;
        this.syncSourceEditor(markdown);
        this.dispatchMarkdownChange(markdown);
    }

    /** Records a valid Markdown change and notifies htmx autosave listeners. */
    private dispatchMarkdownChange(markdown: string): void {
        this.markdown = markdown;
        this.markDirty();
        this.updateWordCount();
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
        this.applyVisualTheme();
        this.syncThemeDropdown();

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
        this.setAttribute("data-save-state", this.saveState);

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

    /** Updates the word count from the current Markdown document. */
    private updateWordCount(): void {
        if (!this.wordCount) {
            return;
        }

        this.wordCount.textContent = wordCountLabel(this.markdown);
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

/** Returns the current selection range when it is non-empty and contained in the given surface. */
function visualSelectionRange(surface: HTMLElement): Range | null {
    const selection = window.getSelection();

    if (!selection || selection.rangeCount === 0 || selection.isCollapsed) {
        return null;
    }

    if (!surface.contains(selection.anchorNode) || !surface.contains(selection.focusNode)) {
        return null;
    }

    return selection.getRangeAt(0);
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
/** Derives a display file name from the document src path. */
function documentFileName(src: string | null): string | null {
    if (!src) {
        return null;
    }

    const segments = src.split("/").filter((segment: string): boolean => segment.length > 0);
    const last = segments.at(-1);

    if (!last) {
        return null;
    }

    return last.includes(".") ? last : `${last}.md`;
}

/** Formats the word count label for the rendered document text. */
function wordCountLabel(markdown: string): string {
    const count = countDocumentWords(markdown);

    return count === 1 ? "1 word" : `${count} words`;
}

/** Counts Markdown source words: whitespace-separated tokens containing a letter or digit. */
function countDocumentWords(markdown: string): number {
    return markdown.split(/\s+/u).filter((token: string): boolean => /[\p{L}\p{N}]/u.test(token)).length;
}

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

/** Returns the shortcut label for inline controls backed by editor keymaps. */
function shortcutForInlineStyle(style: VisualInlineStyle): string | null {
    if (style === "strong") {
        return `${primaryModifierLabel()}+B`;
    }

    if (style === "emphasis") {
        return `${primaryModifierLabel()}+I`;
    }

    if (style === "code") {
        return `${primaryModifierLabel()}+E`;
    }

    if (style === "strikethrough") {
        return `${primaryModifierLabel()}+Shift+S`;
    }

    if (style === "link") {
        return `${primaryModifierLabel()}+K`;
    }

    return null;
}

/** Returns the platform-specific primary command modifier label. */
function primaryModifierLabel(): string {
    return /\bMac/.test(navigator.platform) ? "Cmd" : "Ctrl";
}

/** Reflects disabled state onto custom toolbar command elements. */
function setToolbarButtonDisabled(button: ToolbarButtonElement, disabled: boolean): void {
    if (disabled) {
        button.setAttribute("disabled", "");
        return;
    }

    button.removeAttribute("disabled");
}
