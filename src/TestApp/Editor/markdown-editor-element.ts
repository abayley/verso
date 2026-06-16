import type { AdmonitionKind } from "./admonition-extension.js";
import { BubbleToolbarElement } from "./bubble-toolbar-element.js";
import { CodeMirrorSourceEditor, type CodeMirrorSourceSelection } from "./codemirror-source-editor.js";
import type { CollapsibleKind } from "./collapsible-extension.js";
import {
    CommandBarElement,
    type CommandBlockStyleEventDetail,
    type CommandInlineEventDetail,
    type CommandStructureEventDetail,
} from "./command-bar-element.js";
import { INLINE_COMMANDS } from "./editor-toolbar-shared.js";
import { LinkPopoverController } from "./link-popover-controller.js";
import { renderMarkdown } from "./markdown-render.js";
import { SaveStateController, type SaveStateView } from "./save-state-controller.js";
import { SlashMenuElement, type SlashSelectEventDetail } from "./slash-menu-element.js";
import {
    type TableAlignEventDetail,
    type TableCommandEventDetail,
    TableControlsElement,
} from "./table-controls-element.js";
import {
    TiptapVisualEditor,
    type VisualBlockStyle,
    type VisualInlineStyle,
    type VisualLinkSelection,
    type VisualStructureStyle,
    type VisualTableCommand,
} from "./tiptap-visual-editor.js";
import { ToolbarTooltipController } from "./toolbar-tooltip-controller.js";

type EditorMode = "visual" | "source" | "split";
type EditorTheme = "light" | "dark" | "match-system";
type VisualTheme = "paper" | "aurora" | "blueprint" | "herbarium" | "workbench" | "studio";
type ActivePane = "source" | "visual";
type ToolbarButtonElement = HTMLElement;

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
    /** Participates in form submission natively (RFC-0001), so htmx and ordinary posts share one value. */
    static formAssociated = true;
    private internals: ElementInternals | null = null;
    private body: HTMLDivElement | null = null;
    private activePane: ActivePane | null = null;
    private initialised = false;
    private markdown = "";
    private modeGroup: HTMLElement | null = null;
    private mode: EditorMode = "visual";
    private panes: HTMLDivElement | null = null;
    private parseError: HTMLDivElement | null = null;
    private preview: HTMLDivElement | null = null;
    private linkController: LinkPopoverController | null = null;
    private saveError: HTMLSpanElement | null = null;
    private saveController: SaveStateController | null = null;
    private sourceEditor: CodeMirrorSourceEditor | null = null;
    private syncingEditors = false;
    private theme: EditorTheme = "match-system";
    private themeGroup: HTMLElement | null = null;
    private themeDropdown: HTMLElement | null = null;
    private themeDropdownTrigger: ToolbarButtonElement | null = null;
    private visualTheme: VisualTheme = "paper";
    private tooltipController: ToolbarTooltipController | null = null;
    private readonly handleSystemThemeChange = (): void => {
        if (this.theme === "match-system") {
            this.applyDocumentTheme();
        }
    };
    private readonly handleSelectionChange = (): void => {
        this.updateBubbleToolbar();
        this.updateSlashMenu();
        this.updateTableControls();
    };
    private readonly handleSlashKeydown = (event: KeyboardEvent): void => {
        if (!this.slashMenu || this.slashMenu.hidden) {
            return;
        }

        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            event.stopPropagation();
            const delta = event.key === "ArrowDown" ? 1 : -1;
            this.slashIndex = (this.slashIndex + delta + this.slashCommands.length) % this.slashCommands.length;
            this.highlightSlashItem();
        } else if (event.key === "Enter") {
            event.preventDefault();
            event.stopPropagation();
            const command = this.slashCommands[this.slashIndex];

            if (command) {
                this.runSlashCommand(command.run);
            }
        } else if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            this.closeSlashMenu();
        }
    };
    private bubbleToolbar: BubbleToolbarElement | null = null;
    private slashMenu: SlashMenuElement | null = null;
    private slashCommands: { label: string; run: () => void }[] = [];
    private slashIndex = 0;
    private tableControls: TableControlsElement | null = null;
    private commandBar: CommandBarElement | null = null;
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
        document.removeEventListener("selectionchange", this.handleSelectionChange);
        this.closeSlashMenu();
        this.linkController?.dispose();
        this.tooltipController?.hide();
        this.saveController?.dispose();
        this.sourceEditor?.destroy();
        this.sourceEditor = null;
        this.visualEditor?.destroy();
        this.visualEditor = null;
    }

    /** Initialises the editor UI from inline content or a Markdown `src`. */
    private async initialise(): Promise<void> {
        if (this.initialised) {
            return;
        }

        this.initialised = true;
        this.internals = this.attachFormInternals();
        const fallback = this.fallbackTextarea();
        this.markdown = await this.loadMarkdown();
        this.visualTheme = this.editorVisualTheme();
        this.theme = this.editorTheme();
        this.mode = this.editorMode();
        this.replaceChildren();

        if (fallback) {
            // Adopt the server-rendered textarea but keep it inert: disabled so it
            // does not double-submit, hidden so the rich editor renders alone, but
            // present in the DOM (RFC-0001).
            fallback.disabled = true;
            fallback.hidden = true;
            this.append(fallback);
        }

        this.internals?.setFormValue(this.markdown);
        this.saveController = new SaveStateController(
            (): string => this.toMarkdown(),
            (view: SaveStateView): void => this.applySaveView(view),
        );

        this.tooltipController = new ToolbarTooltipController();
        this.toolbar = this.createToolbar();
        this.commandBar = this.createCommandBar();
        this.linkController = this.createLinkController();
        this.bubbleToolbar = this.createBubbleToolbar();
        this.slashMenu = this.createSlashMenu();
        this.tableControls = this.createTableControls();
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
            this.linkController.editorElement(),
            this.linkController.actionsElement(),
            this.bubbleToolbar,
            this.slashMenu,
            this.tableControls,
            this.tooltipController.element(),
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

    /** Creates the floating Lit command bar and routes its command events to the active editor. */
    private createCommandBar(): CommandBarElement {
        const bar = new CommandBarElement();
        bar.className = "markdown-editor__toolbar markdown-editor__toolbar--commands";
        bar.setAttribute("role", "toolbar");
        bar.tooltipController = this.tooltipController;
        bar.addEventListener("command-block-style", (event: Event): void => {
            const style = (event as CustomEvent<CommandBlockStyleEventDetail>).detail.style;

            if (isVisualBlockStyle(style)) {
                this.setStyleDropdownValue(style);
                this.applyBlockStyle(style);
            }
        });
        bar.addEventListener("command-inline", (event: Event): void => {
            this.toggleInlineStyle((event as CustomEvent<CommandInlineEventDetail>).detail.style);
        });
        bar.addEventListener("command-structure", (event: Event): void => {
            this.toggleStructure((event as CustomEvent<CommandStructureEventDetail>).detail.style);
        });

        return bar;
    }

    /** Creates the document name label shown in the editor top bar. */
    private createDocumentName(): HTMLSpanElement {
        const name = document.createElement("span");
        name.className = "markdown-editor__document-name";
        const fileName = documentFileName(this.getAttribute("data-document") ?? this.getAttribute("src"));
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
        this.tooltipController?.register(option, label);

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

    /** Creates the save error message shown when the last save failed. */
    private createSaveError(): HTMLSpanElement {
        const error = document.createElement("span");
        error.className = "markdown-editor__save-error";
        error.setAttribute("role", "status");
        error.hidden = true;
        this.saveError = error;

        return error;
    }

    /** Creates the link popover controller, wiring its host dependencies (RFC-0002). */
    private createLinkController(): LinkPopoverController {
        return new LinkPopoverController({
            tooltipController: this.tooltipController,
            position: (overlay: HTMLElement, anchor: DOMRect): void => this.positionOverlay(overlay, anchor),
            editorAnchorRect: (anchorRect: DOMRect | null): DOMRect =>
                anchorRect ??
                selectionClientRect() ??
                this.activeEditPaneRect() ??
                this.body?.getBoundingClientRect() ??
                this.getBoundingClientRect(),
            usingSource: (): boolean => this.shouldUseSourceCommands(),
            captureSourceSelection: (): CodeMirrorSourceSelection | null =>
                this.sourceEditor?.currentSelection() ?? null,
            applyLink: (
                href: string,
                sourceSelection: CodeMirrorSourceSelection | null,
                visualSelection: VisualLinkSelection | null,
            ): void => this.applyLinkTarget(href, sourceSelection, visualSelection),
            removeLink: (selection: VisualLinkSelection): void => this.removeVisualLink(selection),
            editorPresent: (): boolean => this.visualEditor !== null,
            visualAnchorAt: (target: Element): HTMLAnchorElement | null => {
                const anchor = target.closest("a");

                return anchor instanceof HTMLAnchorElement && this.visualEditor?.element().contains(anchor)
                    ? anchor
                    : null;
            },
            linkSelectionFromAnchor: (anchor: HTMLAnchorElement): VisualLinkSelection | null =>
                this.visualEditor?.linkSelectionFromAnchor(anchor) ?? null,
        });
    }

    /** Applies a link target to the active pane (the link controller's apply host). */
    private applyLinkTarget(
        href: string,
        sourceSelection: CodeMirrorSourceSelection | null,
        visualSelection: VisualLinkSelection | null,
    ): void {
        if (this.shouldUseSourceCommands()) {
            if (sourceSelection) {
                this.sourceEditor?.toggleLinkAt(sourceSelection, href);
            } else {
                this.sourceEditor?.toggleLink(href);
            }

            return;
        }

        if (visualSelection) {
            if (this.visualEditor?.setLinkAt(visualSelection, href)) {
                this.handleVisualInput();
            }

            return;
        }

        if (this.visualEditor?.toggleInlineStyle("link", href)) {
            this.handleVisualInput();
        }
    }

    /** Removes the link mark at a resolved visual selection (the link controller's remove host). */
    private removeVisualLink(selection: VisualLinkSelection): void {
        if (this.visualEditor?.unsetLinkAt(selection)) {
            this.handleVisualInput();
        }
    }

    /** Creates the Studio selection bubble toolbar and routes its command events to the active editor. */
    private createBubbleToolbar(): BubbleToolbarElement {
        const bubble = new BubbleToolbarElement();
        bubble.className = "markdown-editor__bubble";
        bubble.setAttribute("role", "toolbar");
        bubble.hidden = true;
        bubble.tooltipController = this.tooltipController;
        bubble.addEventListener("command-block-style", (event: Event): void => {
            const style = (event as CustomEvent<CommandBlockStyleEventDetail>).detail.style;

            if (isVisualBlockStyle(style)) {
                this.applyBlockStyle(style);
                this.updateBubbleToolbar();
            }
        });
        bubble.addEventListener("command-inline", (event: Event): void => {
            this.toggleInlineStyle((event as CustomEvent<CommandInlineEventDetail>).detail.style);
            this.updateBubbleToolbar();
        });

        return bubble;
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

        const editor = this.visualEditor;
        this.bubbleToolbar.blockStyle = editor.currentBlockStyle();
        this.bubbleToolbar.activeStyles = INLINE_COMMANDS.map((command) => command.style).filter((style) =>
            editor.isInlineActive(style),
        );
        this.bubbleToolbar.flush();
        this.bubbleToolbar.hidden = false;
        this.positionOverlay(this.bubbleToolbar, range.getBoundingClientRect());
    }

    /** Hides the bubble toolbar. */
    private hideBubbleToolbar(): void {
        if (this.bubbleToolbar) {
            this.bubbleToolbar.hidden = true;
        }
    }

    /** Creates the Studio slash command menu and runs the chosen block or structure command. */
    private createSlashMenu(): SlashMenuElement {
        const menu = new SlashMenuElement();
        menu.className = "markdown-editor__slash-menu";
        menu.setAttribute("role", "listbox");
        menu.hidden = true;
        this.slashCommands = [
            { label: "Heading 1", run: (): void => this.applyBlockStyle("heading-1") },
            { label: "Heading 2", run: (): void => this.applyBlockStyle("heading-2") },
            { label: "Heading 3", run: (): void => this.applyBlockStyle("heading-3") },
            { label: "Bullet list", run: (): void => this.toggleStructure("bullet-list") },
            { label: "Numbered list", run: (): void => this.toggleStructure("ordered-list") },
            { label: "Quote", run: (): void => this.toggleStructure("blockquote") },
            { label: "Code block", run: (): void => this.toggleStructure("code-block") },
            { label: "Note callout", run: (): void => this.insertAdmonition("note") },
            { label: "Collapsible", run: (): void => this.insertCollapsible("note") },
            { label: "Table", run: (): void => this.insertTable() },
        ];
        menu.items = this.slashCommands.map((command) => command.label);
        menu.addEventListener("slash-select", (event: Event): void => {
            const command = this.slashCommands[(event as CustomEvent<SlashSelectEventDetail>).detail.index];

            if (command) {
                this.runSlashCommand(command.run);
            }
        });

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

        this.highlightSlashItem();
        this.slashMenu.hidden = false;
        const caret = this.visualEditor.slashCaretRect() ?? this.activeEditPaneRect();

        if (caret) {
            this.positionOverlay(this.slashMenu, caret);
        }
    }

    /** Creates the floating Lit table-editing controls and routes their events to table commands. */
    private createTableControls(): TableControlsElement {
        const controls = new TableControlsElement();
        controls.className = "markdown-editor__table-controls";
        controls.hidden = true;
        controls.addEventListener("table-command", (event: Event): void => {
            this.runTableCommand((event as CustomEvent<TableCommandEventDetail>).detail.command);
        });
        controls.addEventListener("table-align", (event: Event): void => {
            this.alignTableColumn((event as CustomEvent<TableAlignEventDetail>).detail.align);
        });

        return controls;
    }

    /** Shows the table controls anchored to the current table when the visual selection is inside one. */
    private updateTableControls(): void {
        if (!this.tableControls) {
            return;
        }

        const rect = this.shouldUseSourceCommands()
            ? null
            : this.visualEditor?.isInTable()
              ? this.visualEditor.tableRect()
              : null;

        if (!rect) {
            this.tableControls.hidden = true;
            return;
        }

        this.tableControls.hidden = false;
        this.positionOverlay(this.tableControls, rect);
    }

    /** Runs a table-editing command through the visual editor and refreshes the controls. */
    private runTableCommand(command: VisualTableCommand): void {
        if (this.visualEditor?.runTableCommand(command)) {
            this.handleVisualInput();
            this.updateTableControls();
        }
    }

    /** Sets the GFM column alignment on the selected table cells. */
    private alignTableColumn(align: "left" | "center" | "right"): void {
        if (this.visualEditor?.setColumnAlignment(align)) {
            this.handleVisualInput();
        }
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
        if (this.slashMenu) {
            this.slashMenu.activeIndex = this.slashIndex;
            this.slashMenu.flush();
        }
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
        this.tooltipController?.register(button, label, shortcut);

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

            if (this.linkController) {
                this.visualEditor
                    .element()
                    .addEventListener("pointerover", this.linkController.handleVisualPointerOver);
            }
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
    /** Attaches form internals, tolerating runtimes (e.g. happy-dom) without support. */
    private attachFormInternals(): ElementInternals | null {
        try {
            return this.attachInternals();
        } catch {
            return null;
        }
    }

    /** The server-rendered Markdown fallback textarea wrapped by this element, if any. */
    private fallbackTextarea(): HTMLTextAreaElement | null {
        const element = this.querySelector("textarea");

        return element instanceof HTMLTextAreaElement ? element : null;
    }

    private async loadMarkdown(): Promise<string> {
        const fallback = this.fallbackTextarea();

        if (fallback) {
            return fallback.value;
        }

        const src = this.getAttribute("src");

        if (!src) {
            return this.textContent?.trim() ?? "";
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
            this.linkController?.openEditor();
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

    /** Opens link editing from a source-pane keyboard shortcut. */
    private handleSourceLinkShortcut(): void {
        this.activePane = "source";
        this.linkController?.openEditor();
    }

    /** Opens link editing from a visual-pane keyboard shortcut. */
    private handleVisualLinkShortcut(): void {
        this.activePane = "visual";
        this.linkController?.openEditor();
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

    /** Inserts an admonition callout of the given kind at the current visual selection. */
    private insertAdmonition(kind: AdmonitionKind): void {
        if (this.visualEditor?.insertAdmonition(kind)) {
            this.handleVisualInput();
        }
    }

    /** Inserts a collapsible callout of the given type at the current visual selection. */
    private insertCollapsible(kind: CollapsibleKind): void {
        if (this.visualEditor?.insertCollapsible(kind)) {
            this.handleVisualInput();
        }
    }

    /** Inserts a table at the current visual selection. */
    private insertTable(): void {
        if (this.visualEditor?.insertTable()) {
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
        this.updateTableControls();
    }

    /** Records a valid Markdown change and notifies htmx autosave listeners. */
    private dispatchMarkdownChange(markdown: string): void {
        this.markdown = markdown;
        this.internals?.setFormValue(markdown);
        this.saveController?.markDirty();
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

        if (!(form instanceof HTMLFormElement)) {
            return;
        }

        // The current Markdown reaches the server natively through ElementInternals
        // (RFC-0001); this also writes it into the htmx request parameters so an
        // htmx autosave carries the live value regardless of how htmx collects
        // form-associated custom element values.
        form.addEventListener("htmx:configRequest", (event: Event): void => {
            const markdown = this.toMarkdown();
            const htmxEvent = event as HtmxConfigRequestEvent;

            htmxEvent.detail.parameters["markdown"] = markdown;
            this.saveController?.markSubmitted(markdown);
        });
        form.addEventListener("htmx:beforeRequest", (): void => {
            this.saveController?.markSaving();
        });
        form.addEventListener("htmx:afterRequest", (event: Event): void => {
            const detail = (event as HtmxAfterRequestEvent).detail;
            const successful = detail.successful ?? isSuccessfulStatus(detail.xhr?.status);

            if (successful) {
                this.saveController?.markSucceeded();
            } else {
                this.saveController?.markFailed(saveFailureReason(event as HtmxAfterRequestEvent));
            }
        });
        form.addEventListener("htmx:responseError", (): void => {
            this.saveController?.markFailed("connection error");
        });
        form.addEventListener("htmx:sendError", (): void => {
            this.saveController?.markFailed("connection error");
        });
        form.addEventListener("htmx:timeout", (): void => {
            this.saveController?.markFailed("request timed out");
        });
    }

    /** Renders the save controller's reported view onto the Save button and error text. */
    private applySaveView(view: SaveStateView): void {
        this.setAttribute("data-save-state", view.state);

        if (this.commandBar) {
            this.commandBar.saveLabel = view.buttonLabel;
            this.commandBar.saveDisabled = view.buttonDisabled;
            this.commandBar.flush();
        }

        if (this.saveError) {
            this.saveError.textContent = view.error ?? "";
            this.saveError.hidden = view.error === null;
        }
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

        if (this.commandBar) {
            this.commandBar.commandsDisabled = !this.visualEditor && !this.sourceEditor;
        }

        this.setStyleDropdownValue("paragraph");

        if (this.saveController) {
            this.applySaveView(this.saveController.view());
        }
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

    /** Reflects the current block style onto the command bar's style dropdown. */
    private setStyleDropdownValue(style: VisualBlockStyle): void {
        if (this.commandBar) {
            this.commandBar.blockStyle = style;
            this.commandBar.flush();
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
