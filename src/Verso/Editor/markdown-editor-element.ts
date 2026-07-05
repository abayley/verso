import { ADMONITION_KINDS, type AdmonitionKind, admonitionTitle } from "./admonition-extension.js";
import {
    ATTACHMENT_DRAG_TYPE,
    AttachmentPanel,
    attachmentLinkMarkdown,
    type PanelAttachment,
    parseEmbeddedAttachments,
} from "./attachment-panel.js";
import { attachmentMarkdown, isInlineImage, uploadAttachment } from "./attachment-upload.js";
import { badgeExtension } from "./badge-extension.js";
import { type Breadcrumb, parseBreadcrumbs } from "./breadcrumbs.js";
import { BubbleToolbarElement } from "./bubble-toolbar-element.js";
import { type ClientErrorKind, ClientErrorReporter } from "./client-error-reporter.js";
import { CodeMirrorSourceEditor, type CodeMirrorSourceSelection } from "./codemirror-source-editor.js";
import type { CollapsibleKind } from "./collapsible-extension.js";
import {
    type CommandBadgeEventDetail,
    CommandBarElement,
    type CommandBlockStyleEventDetail,
    type CommandInlineEventDetail,
    type CommandInsertStructureEventDetail,
    type CommandStructureEventDetail,
    type InsertStructureKind,
} from "./command-bar-element.js";
import { themedConfirm } from "./confirm-dialog.js";
import { registerExtension } from "./content-extension.js";
import { INLINE_COMMANDS } from "./editor-toolbar-shared.js";
import { frontmatterName, joinFrontmatter, setFrontmatterName, splitFrontmatter } from "./frontmatter.js";
import { imageShortTitles } from "./image-metadata.js";
import { LinkPopoverController } from "./link-popover-controller.js";
import {
    type DeleteResult,
    type MoveOp,
    type MoveResult,
    NavTreePanel,
    type OpResult,
    parseTreeChildren,
    parseTreeSpine,
    type TrashEntry,
    type TreeNodeData,
} from "./nav-tree.js";
import { rawHtmlExtension } from "./raw-html-extension.js";
import { SaveStateController, type SaveStateView } from "./save-state-controller.js";
import { SearchPanel } from "./search-panel.js";
import { SlashMenuElement, type SlashSelectEventDetail } from "./slash-menu-element.js";
import {
    type TableAlignEventDetail,
    type TableCommandEventDetail,
    TableControlsElement,
} from "./table-controls-element.js";
import { documentHeadings, TableOfContentsPanel } from "./table-of-contents.js";
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
type BodyWidth = "narrow" | "medium" | "full";
type VisualTheme = "paper" | "aurora" | "blueprint" | "workbench" | "studio";
type ActivePane = "source" | "visual";
type ToolbarButtonElement = HTMLElement;

const visualThemeStorageKey = "editor-theme";
const colorSchemeStorageKey = "editor-color-scheme";
const bodyWidthStorageKey = "editor-body-width";
const modeStorageKey = "editor-mode";

/** The selectable editing-column widths, in toolbar order; "narrow" is the default. */
const bodyWidths: { value: BodyWidth; label: string }[] = [
    { value: "narrow", label: "Narrow" },
    { value: "medium", label: "Medium" },
    { value: "full", label: "Full" },
];

/** Narrows an arbitrary string to a known editing-column width. */
function isBodyWidth(value: string | null): value is BodyWidth {
    return value !== null && bodyWidths.some((width) => width.value === value);
}

/** The selectable visual themes, in lexicographic dropdown order (the default is Paper, set explicitly). */
const visualThemes: { value: VisualTheme; label: string }[] = [
    { value: "aurora", label: "Aurora" },
    { value: "blueprint", label: "Blueprint" },
    { value: "paper", label: "Paper" },
    { value: "studio", label: "Studio" },
    { value: "workbench", label: "Workbench" },
];

/** Narrows an arbitrary string to a known visual theme. */
function isVisualTheme(value: string | null): value is VisualTheme {
    return value !== null && visualThemes.some((theme) => theme.value === value);
}

/**
 * One entry in the Studio slash command menu. A leaf carries `run`; a group carries `children` and, when
 * chosen, opens those as a submenu instead of running; the synthetic back entry carries `back`.
 */
interface SlashCommand {
    label: string;
    run?: () => void;
    children?: SlashCommand[];
    back?: boolean;
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

/** Whether a theme arranges the presentation controls as a vertical left rail (the Workbench IDE frame). */
function themeUsesWorkbenchRail(theme: VisualTheme): boolean {
    return theme === "workbench";
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
    /** The document's preserved YAML frontmatter (verbatim), hidden from editing and re-attached on save. */
    private frontmatter: string | null = null;
    private modeGroup: HTMLElement | null = null;
    private widthGroup: HTMLElement | null = null;
    private bodyWidth: BodyWidth = "narrow";
    private attachmentPanel: AttachmentPanel | null = null;
    private tocPanel: TableOfContentsPanel | null = null;
    /** The left-hand navigation tree (tree mode only, RFC-0026). */
    private navTree: NavTreePanel | null = null;
    /** The page-title field above the editing pane: an editable input, or read-only text in the read view. */
    private titleField: HTMLElement | null = null;
    /** The right-hand sidebar holding the contents panel and (in tree mode) the attachments panel. */
    private sidebar: HTMLDivElement | null = null;
    private mode: EditorMode = "visual";
    private panes: HTMLDivElement | null = null;
    private linkController: LinkPopoverController | null = null;
    private saveError: HTMLSpanElement | null = null;
    private errorBanner: HTMLDivElement | null = null;
    /** The single notification area (save + client errors, upload notices); relocated per theme. */
    private notices: HTMLDivElement | null = null;
    private footer: HTMLDivElement | null = null;
    private readonly clientErrorReporter = new ClientErrorReporter();
    private saveController: SaveStateController | null = null;
    private sourceEditor: CodeMirrorSourceEditor | null = null;
    private syncingEditors = false;
    /**
     * Whether there is unpublished work to discard (RFC-0032): true once the author edits the document, and
     * seeded true when a staged draft was resumed on load. Cancel only confirms when this is set, so cancelling
     * an untouched page (no draft, no edits) leaves quietly without a dialog.
     */
    private hasUnpublishedChanges = false;
    /**
     * True while {@link renderMode} is (re)building the editors. Their construction normalises the loaded
     * Markdown and dispatches transactions that fire the change handlers; those are not user edits, so they
     * must not mark the document dirty (which would otherwise autosave on load and on every mode switch).
     */
    private buildingEditors = false;
    private theme: EditorTheme = "match-system";
    private themeGroup: HTMLElement | null = null;
    private themeDropdown: HTMLElement | null = null;
    private themeDropdownTrigger: ToolbarButtonElement | null = null;
    private visualTheme: VisualTheme = "paper";
    private tooltipController: ToolbarTooltipController | null = null;
    /** A faster (200 ms) tooltip just for the navigation tree's truncated labels (RFC-0026). */
    private navTooltipController: ToolbarTooltipController | null = null;
    private readonly handleSystemThemeChange = (): void => {
        if (this.theme === "match-system") {
            this.applyDocumentTheme();
        }
    };
    // Catch-all error surfacing (RFC-0022): an uncaught error or rejection anywhere on the editor page
    // raises the dismissible banner rather than leaving a silently broken editor. The editor is the whole
    // page in this app, so page-level errors are treated as editor-originated.
    private readonly handleGlobalError = (event: ErrorEvent): void => {
        // Ignore benign browser noise (notably the harmless "ResizeObserver loop" notification emitted during
        // dynamic layout, e.g. the Workbench split). It carries no error object, recurs as the layout settles,
        // and would otherwise raise the banner repeatedly so it could never be dismissed.
        if (isIgnorableGlobalError(event.message)) {
            return;
        }

        this.showErrorBanner(event.error ?? event.message, "error");
    };
    private readonly handleUnhandledRejection = (event: PromiseRejectionEvent): void => {
        this.showErrorBanner(event.reason, "unhandledrejection");
    };
    private readonly handleSelectionChange = (): void => {
        this.updateBubbleToolbar();
        this.updateSlashMenu();
        this.updateTableControls();
        this.updateCursorPosition();
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
            this.selectSlashItem(this.slashIndex);
        } else if (event.key === "ArrowLeft" && this.slashStack.length > 0) {
            // Inside a submenu, Left steps back a level (mirrors Right/Enter opening one).
            event.preventDefault();
            event.stopPropagation();
            this.exitSlashSubmenu();
        } else if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();
            // Escape backs out of a submenu one level at a time, then closes the menu.
            if (this.slashStack.length > 0) {
                this.exitSlashSubmenu();
            } else {
                this.closeSlashMenu();
            }
        }
    };
    private bubbleToolbar: BubbleToolbarElement | null = null;
    private slashMenu: SlashMenuElement | null = null;
    /** The top-level slash commands (the root menu level). */
    private slashRoot: SlashCommand[] = [];
    /** The slash commands currently displayed (the root, or an opened submenu with a leading Back entry). */
    private slashCommands: SlashCommand[] = [];
    /** Parent levels awaiting return, pushed when a submenu opens and popped by Back. */
    private slashStack: SlashCommand[][] = [];
    private slashIndex = 0;
    private tableControls: TableControlsElement | null = null;
    private commandBar: CommandBarElement | null = null;
    private uploadNotice: HTMLDivElement | null = null;
    private fileInput: HTMLInputElement | null = null;
    private readonly handleDragOver = (event: DragEvent): void => {
        if (dragHasFiles(event.dataTransfer)) {
            event.preventDefault();
        }
    };
    private readonly handleDrop = (event: DragEvent): void => {
        const files = filesFromDataTransfer(event.dataTransfer);

        if (files.length > 0) {
            event.preventDefault();
            void this.uploadFiles(files);
        }
    };
    private readonly handlePaste = (event: ClipboardEvent): void => {
        const files = filesFromDataTransfer(event.clipboardData);

        if (files.length > 0) {
            event.preventDefault();
            void this.uploadFiles(files);
        }
    };
    private documentName: HTMLElement | null = null;
    private toolbar: HTMLDivElement | null = null;
    private topBar: HTMLDivElement | null = null;
    /** Publishes the sticky top bar's height as a CSS variable so the nav/sidebar can sit clear of it. */
    private topBarResizeObserver: ResizeObserver | null = null;
    private visualEditor: TiptapVisualEditor | null = null;
    private visualEditorChanged = false;
    private wordCount: HTMLSpanElement | null = null;
    /** The status-bar caret-position readout (Workbench chrome); empty when no source pane is shown. */
    private cursorReadout: HTMLSpanElement | null = null;
    /** The status-bar word-count readout. */
    private wordReadout: HTMLSpanElement | null = null;

    /** Starts asynchronous element initialisation after connection. */
    connectedCallback(): void {
        if (this.initialised) {
            return;
        }

        // Create the error banner before initialising so an initialisation failure (e.g. a document the
        // renderer chokes on) can surface in the UI instead of leaving a blank editor. It is attached during
        // initialise (after the inline content is read), or on demand by showErrorBanner if a failure occurs
        // first; it is a top-level child, not a footer notice, so it stays visible in the read view.
        this.errorBanner = this.createErrorBanner();
        window.addEventListener("error", this.handleGlobalError);
        window.addEventListener("unhandledrejection", this.handleUnhandledRejection);

        window.setTimeout((): void => {
            this.initialise().catch((error: unknown): void => {
                this.showErrorBanner(error);
            });
        }, 0);
    }

    /** Cleans up editor resources when the element leaves the document. */
    disconnectedCallback(): void {
        window.removeEventListener("error", this.handleGlobalError);
        window.removeEventListener("unhandledrejection", this.handleUnhandledRejection);
        this.systemThemeQuery()?.removeEventListener("change", this.handleSystemThemeChange);
        document.removeEventListener("selectionchange", this.handleSelectionChange);
        this.body?.removeEventListener("dragover", this.handleDragOver);
        this.body?.removeEventListener("drop", this.handleDrop);
        this.body?.removeEventListener("paste", this.handlePaste, true);
        this.closeSlashMenu();
        this.linkController?.dispose();
        this.tooltipController?.hide();
        this.navTooltipController?.hide();
        this.saveController?.dispose();
        this.sourceEditor?.destroy();
        this.sourceEditor = null;
        this.visualEditor?.destroy();
        this.visualEditor = null;
        this.topBarResizeObserver?.disconnect();
        this.topBarResizeObserver = null;
    }

    /** Publishes the sticky top bar's height to `--markdown-editor-topbar-height`, tracking it as it wraps. */
    private observeTopBarHeight(): void {
        if (!this.topBar) {
            return;
        }

        const publish = (): void => {
            const height = this.topBar?.offsetHeight ?? 0;
            this.style.setProperty("--markdown-editor-topbar-height", `${height}px`);
        };
        publish();
        this.topBarResizeObserver = new ResizeObserver(publish);
        this.topBarResizeObserver.observe(this.topBar);
    }

    /** Initialises the editor UI from inline content or a Markdown `src`. */
    private async initialise(): Promise<void> {
        if (this.initialised) {
            return;
        }

        this.initialised = true;
        this.internals = this.attachFormInternals();
        const fallback = this.fallbackTextarea();
        const loaded = splitFrontmatter(await this.loadMarkdown());
        this.frontmatter = loaded.frontmatter;
        this.markdown = loaded.body;

        if (this.isTreeMode()) {
            // The trusted document tree may contain raw HTML (export-metadata comments, occasional
            // markup); preserve it verbatim and inert rather than throwing on it (ADR-040/041 reject raw
            // HTML only in the untrusted flat mode). Badge lozenges (RFC-0021) are likewise tree-only.
            registerExtension(rawHtmlExtension);
            registerExtension(badgeExtension);
        }

        this.visualTheme = this.editorVisualTheme();
        this.theme = this.editorTheme();
        this.mode = this.editorMode();
        this.bodyWidth = this.editorBodyWidth();
        this.replaceChildren();

        // Re-attach the error banner cleared by replaceChildren so it stays present for the rest of
        // initialisation (and visible if a later step here throws).
        if (this.errorBanner) {
            this.append(this.errorBanner);
        }

        if (fallback) {
            // Adopt the server-rendered textarea but keep it inert: disabled so it
            // does not double-submit, hidden so the rich editor renders alone, but
            // present in the DOM (RFC-0001).
            fallback.disabled = true;
            fallback.hidden = true;
            this.append(fallback);
        }

        this.internals?.setFormValue(this.documentMarkdown());
        this.saveController = new SaveStateController(
            (): string => this.toMarkdown(),
            (view: SaveStateView): void => this.applySaveView(view),
        );
        // A resumed draft is itself unpublished work to discard (RFC-0032); a fresh page starts clean.
        this.hasUnpublishedChanges = this.hasAttribute("data-has-draft");

        this.tooltipController = new ToolbarTooltipController();
        this.toolbar = this.createToolbar();
        this.documentName = this.createDocumentName();
        this.commandBar = this.createCommandBar();
        this.linkController = this.createLinkController();
        this.bubbleToolbar = this.createBubbleToolbar();
        this.slashMenu = this.createSlashMenu();
        this.tableControls = this.createTableControls();
        this.body = document.createElement("div");
        this.body.className = "markdown-editor__body";
        this.wordCount = document.createElement("span");
        this.wordCount.className = "markdown-editor__word-count";
        // A status line carrying the caret position and the word count. The caret position only surfaces
        // under the Workbench theme's status-bar chrome (CSS-gated); the other themes show the word count
        // alone, as before.
        const statusMeta = document.createElement("span");
        statusMeta.className = "markdown-editor__status-meta";
        this.cursorReadout = document.createElement("span");
        this.cursorReadout.className = "markdown-editor__status-cursor";
        this.wordReadout = document.createElement("span");
        this.wordReadout.className = "markdown-editor__status-words";
        statusMeta.append(this.cursorReadout, this.wordReadout);
        this.wordCount.append(statusMeta);

        this.uploadNotice = document.createElement("div");
        this.uploadNotice.className = "markdown-editor__upload-notice";
        this.uploadNotice.setAttribute("role", "status");
        this.uploadNotice.hidden = true;

        // The single notification area: upload notices, the save error, and the client-error banner all live
        // here, so a theme has exactly one place for messages. It sits in the footer (above the command bar)
        // for most themes; applyVisualTheme relocates it into the status row under Workbench.
        this.notices = document.createElement("div");
        this.notices.className = "markdown-editor__notices";
        this.notices.append(this.uploadNotice, this.createSaveError());
        if (this.errorBanner) {
            this.notices.append(this.errorBanner);
        }

        this.footer = document.createElement("div");
        this.footer.className = "markdown-editor__footer";
        this.footer.append(this.notices, this.commandBar);

        const workspace = document.createElement("div");
        workspace.className = "markdown-editor__workspace";

        // The editing column: the page-title field (from the frontmatter `name`, edited here and saved back)
        // sits above the body, sized to match it. The body is the main edit/view pane.
        const main = document.createElement("div");
        main.className = "markdown-editor__main";
        this.titleField = this.createTitleField();
        main.append(this.titleField, this.body);
        workspace.append(main);

        // The right-hand sidebar: the generated contents panel sits above the attachments panel. The contents
        // panel shows whenever the document has headings (any mode); the attachments panel is tree-mode only.
        this.sidebar = document.createElement("div");
        this.sidebar.className = "markdown-editor__sidebar";
        // The interactive search box (RFC-0034) sits at the top of the sidebar, under the
        // top bar's theme and appearance controls; it hides itself when search is disabled.
        if (this.isTreeMode()) {
            const searchPanel = new SearchPanel();
            this.sidebar.append(searchPanel.element());
            void searchPanel.connect();
        }
        this.tocPanel = new TableOfContentsPanel((index: number): void => this.scrollToHeading(index));
        this.sidebar.append(this.tocPanel.element());
        if (this.isTreeMode()) {
            this.attachmentPanel = new AttachmentPanel(
                (attachment: PanelAttachment): void => this.insertAttachmentLink(attachment),
                this.isReadonly(),
            );
            this.attachmentPanel.setAttachments(parseEmbeddedAttachments(this.getAttribute("data-attachments")));
            this.sidebar.append(this.attachmentPanel.element());
            this.sidebar.append(this.createHistoryPanel());
            if (!this.isReadonly()) {
                this.enableAttachmentDrop(this.body);
            }
        }
        // The navigation tree (RFC-0026), tree mode only: the workspace's leading column, so it sits below the
        // top bar and breadcrumbs and to the left of the editing pane (RFC-0026 position revision).
        if (this.isTreeMode()) {
            this.navTooltipController = new ToolbarTooltipController(200);
            this.navTree = this.createNavTree();
            workspace.insertBefore(this.navTree.element(), main);
            this.append(this.navTooltipController.element());
        }
        workspace.append(this.sidebar);

        // The top bar (presentation controls + breadcrumb) is one unit so it can stick to the top of the
        // viewport as a whole while the content scrolls (RFC-0026 follow-up); Workbench flattens it back to
        // two grid items with `display: contents`.
        this.topBar = document.createElement("div");
        this.topBar.className = "markdown-editor__topbar";
        this.topBar.append(this.toolbar, this.documentName);

        this.append(
            this.topBar,
            this.linkController.editorElement(),
            this.linkController.actionsElement(),
            this.bubbleToolbar,
            this.slashMenu,
            this.tableControls,
            this.tooltipController.element(),
            workspace,
            this.footer,
            this.wordCount,
        );
        this.applyBodyWidth();
        this.observeTopBarHeight();
        this.renderMode();
        this.updateToolbarState();
        this.updateWordCount();
        this.updateCursorPosition();
        this.updateTableOfContents();
        this.systemThemeQuery()?.addEventListener("change", this.handleSystemThemeChange);
        document.addEventListener("selectionchange", this.handleSelectionChange);

        // The read view (RFC-0020) has no write path: no upload, no autosave form. Wire those only when
        // editable. (The bottom bar and floating editing affordances are hidden by CSS keyed on data-readonly.)
        if (!this.isReadonly()) {
            this.fileInput = this.createFileInput();
            this.append(this.fileInput);
            this.configureFormSubmission();
            this.body.addEventListener("dragover", this.handleDragOver);
            this.body.addEventListener("drop", this.handleDrop);
            this.body.addEventListener("paste", this.handlePaste, true);
        }
    }

    /**
     * Builds the navigation tree panel (RFC-0026): seeded with the embedded ancestor spine, fetching deeper
     * folders lazily from `/tree`, creating pages/sections via `POST /tree`, and navigating on click. Edit
     * intent is preserved -- navigating from the edit view keeps `?edit`.
     */
    private createNavTree(): NavTreePanel {
        const editMode = !this.isReadonly();
        const encodePath = (path: string): string =>
            path
                .split("/")
                .map((segment): string => encodeURIComponent(segment))
                .join("/");
        return new NavTreePanel({
            documentPath: this.getAttribute("data-document") ?? "",
            spine: parseTreeSpine(this.getAttribute("data-tree-spine")),
            fetchChildren: async (path: string): Promise<TreeNodeData[]> => {
                const response = await fetch(`/tree/${encodePath(path)}`, { headers: { Accept: "application/json" } });
                if (!response.ok) {
                    throw new Error(`Failed to load tree children: ${response.status}`);
                }
                return parseTreeChildren(await response.text());
            },
            createNode: async (parentPath: string, kind: "page" | "section", title: string): Promise<string | null> => {
                const response = await fetch(`/tree/${encodePath(parentPath)}`, {
                    method: "POST",
                    headers: { "Content-Type": "application/x-www-form-urlencoded" },
                    body: new URLSearchParams({ kind, title }).toString(),
                });
                if (!response.ok) {
                    return null;
                }
                const data: unknown = JSON.parse(await response.text());
                const editPath =
                    data && typeof data === "object" ? (data as Record<string, unknown>)["editPath"] : null;
                return typeof editPath === "string" ? editPath : null;
            },
            navigate: (target: string): void => {
                const suffix = editMode && !target.includes("?") ? "?edit" : "";
                window.location.href = `/documents/${target}${suffix}`;
            },
            registerTooltip: (target: HTMLElement, text: string): void =>
                this.navTooltipController?.register(target, text),
            notify: (message: string, isError: boolean): void => this.showUploadNotice(message, isError),
            deleteNode: async (path: string): Promise<DeleteResult> => {
                try {
                    const response = await fetch(`/tree/${encodePath(path)}?delete`, { method: "POST" });
                    if (response.status === 409) {
                        const data: unknown = safeJson(await response.text());
                        const referrers =
                            data &&
                            typeof data === "object" &&
                            Array.isArray((data as Record<string, unknown>)["referrers"])
                                ? ((data as Record<string, unknown>)["referrers"] as { page: string; link: string }[])
                                : undefined;
                        return referrers
                            ? { status: "refused", referrers }
                            : { status: "error", message: (await response.text()).trim() || "Delete refused." };
                    }
                    return response.ok ? { status: "deleted" } : { status: "error", message: "Delete failed." };
                } catch {
                    return { status: "error", message: NETWORK_ERROR };
                }
            },
            moveNode: async (path: string, destParent: string, slug: string, confirm: boolean): Promise<MoveResult> => {
                try {
                    const body = new URLSearchParams({ to: destParent, slug, ...(confirm ? { confirm: "true" } : {}) });
                    const response = await fetch(`/tree/${encodePath(path)}?move`, {
                        method: "POST",
                        headers: { "Content-Type": "application/x-www-form-urlencoded" },
                        body: body.toString(),
                    });
                    if (!response.ok) {
                        return { ok: false, message: (await response.text()).trim() || "Move failed." };
                    }
                    const data: unknown = safeJson(await response.text());
                    const record = data && typeof data === "object" ? (data as Record<string, unknown>) : {};
                    const changed = Array.isArray(record["changed"]) ? (record["changed"] as unknown[]).length : 0;
                    return typeof record["to"] === "string"
                        ? { ok: true, changed, to: record["to"] as string }
                        : { ok: true, changed };
                } catch {
                    return { ok: false, message: NETWORK_ERROR };
                }
            },
            undo: (seq: number): Promise<OpResult> =>
                opRequest(
                    "/undo",
                    {
                        method: "POST",
                        headers: { "Content-Type": "application/x-www-form-urlencoded" },
                        body: new URLSearchParams({ seq: String(seq) }).toString(),
                    },
                    "Undone.",
                    "Nothing to undo.",
                ),
            listMoves: async (): Promise<MoveOp[]> => {
                try {
                    const response = await fetch("/operations", { headers: { Accept: "application/json" } });
                    if (!response.ok) {
                        return [];
                    }
                    const data: unknown = safeJson(await response.text());
                    if (!Array.isArray(data)) {
                        return [];
                    }
                    return (data as Record<string, unknown>[])
                        .filter(
                            (op): boolean =>
                                op["type"] === "move" &&
                                typeof op["from"] === "string" &&
                                typeof op["to"] === "string" &&
                                typeof op["seq"] === "number",
                        )
                        .map(
                            (op): MoveOp => ({
                                seq: op["seq"] as number,
                                from: op["from"] as string,
                                to: op["to"] as string,
                            }),
                        );
                } catch {
                    return [];
                }
            },
            listTrash: async (): Promise<TrashEntry[]> => {
                try {
                    const response = await fetch("/trash", { headers: { Accept: "application/json" } });
                    if (!response.ok) {
                        return [];
                    }
                    const data: unknown = safeJson(await response.text());
                    return Array.isArray(data) ? (data as TrashEntry[]) : [];
                } catch {
                    return [];
                }
            },
            restore: (id: string): Promise<OpResult> =>
                opRequest(`/trash/${encodeURIComponent(id)}`, { method: "POST" }, "Restored.", "Restore failed."),
        });
    }

    /** Creates the hidden file input the toolbar and slash commands trigger for uploads. */
    private createFileInput(): HTMLInputElement {
        const input = document.createElement("input");
        input.type = "file";
        input.hidden = true;
        input.multiple = true;
        input.addEventListener("change", (): void => {
            const files = input.files ? Array.from(input.files) : [];
            input.value = "";

            if (files.length > 0) {
                void this.uploadFiles(files);
            }
        });

        return input;
    }

    /** Creates the top editor bar: the view controls on one line, the document name on its own line below. */
    private createToolbar(): HTMLDivElement {
        const toolbar = document.createElement("div");
        toolbar.className = "markdown-editor__toolbar markdown-editor__toolbar--top";

        const controls = document.createElement("div");
        controls.className = "markdown-editor__toolbar-controls";
        const readEditLink = this.createReadEditLink();
        if (readEditLink) {
            controls.append(readEditLink);
        }
        this.modeGroup = this.createModeGroup();
        controls.append(this.modeGroup);
        this.widthGroup = this.createWidthGroup();
        controls.append(this.widthGroup);
        // The visual-theme dropdown and the light/dark appearance group travel together as one unit
        // ("appearance"). The default themes render it inline at the right of the top bar; Workbench pins
        // it to the top-right of its IDE frame (out of the left rail) via this wrapper.
        const appearance = document.createElement("div");
        appearance.className = "markdown-editor__appearance";
        this.themeDropdown = this.createThemeDropdown();
        appearance.append(this.themeDropdown);
        this.themeGroup = this.createThemeGroup();
        appearance.append(this.themeGroup);
        controls.append(appearance);

        // The document name is a sibling of the controls (not nested), so the layout can place the two
        // independently: stacked below the controls under the default themes (controls, then the name on its
        // own line, so a long page name never pushes a control onto a second line), but split apart under
        // Workbench -- the controls become the left rail while the name rides in the top bar as a file tab.
        toolbar.append(controls);

        return toolbar;
    }

    /**
     * The read/edit toggle for tree documents. In the read view it is an "Edit" link (-> `?edit`), with an
     * "(unpublished draft)" marker appended when the page has a staged draft (RFC-0032, signalled by the
     * server's `data-has-draft` attribute). In the edit view it is a "Publish" button (RFC-0032): publishing
     * commits the staged edit to the tree and exits to the read view -- the way to leave edit mode. The "Edit"
     * link is plain navigation (works without JavaScript); Publish needs JavaScript, as editing itself does.
     * Returns null outside tree mode, where the read/edit selectors do not apply.
     */
    private createReadEditLink(): HTMLElement | null {
        if (!this.isTreeMode()) {
            return null;
        }

        const documentPath = this.getAttribute("data-document") ?? "";
        const group = window.document.createElement("span");
        group.className = "markdown-editor__view-toggle-group";

        if (this.isReadonly()) {
            const link = window.document.createElement("a");
            link.className = "markdown-editor__view-toggle";
            link.href = `/documents/${documentPath}?edit`;
            link.textContent = "Edit";
            group.append(link);

            if (this.hasAttribute("data-has-draft")) {
                const marker = window.document.createElement("span");
                marker.className = "markdown-editor__draft-marker";
                marker.textContent = "(unpublished draft)";
                group.append(marker);
            }
        } else {
            const publish = window.document.createElement("button");
            publish.type = "button";
            publish.className = "markdown-editor__view-toggle markdown-editor__publish";
            publish.textContent = "Publish";
            publish.addEventListener("click", (): void => {
                void this.publishDocument(documentPath);
            });

            const cancel = window.document.createElement("button");
            cancel.type = "button";
            cancel.className = "markdown-editor__view-toggle markdown-editor__cancel";
            cancel.textContent = "Cancel";
            cancel.addEventListener("click", (): void => {
                void this.discardDraft(documentPath);
            });

            group.append(publish, cancel);
        }

        return group;
    }

    /**
     * Discards the staged draft (RFC-0032): drops it via ?discard-draft so the page reverts to its last
     * published (committed) version, then returns to the read view. Confirms first, since it abandons changes.
     */
    private async discardDraft(documentPath: string): Promise<void> {
        // Nothing edited and no resumed draft: leave edit mode quietly, no dialog and no request.
        if (!this.hasUnpublishedChanges) {
            window.location.href = `/documents/${documentPath}`;
            return;
        }

        const confirmed = await themedConfirm({
            title: "Discard changes?",
            message: "Discard your unpublished changes and revert to the last published version?",
            confirmLabel: "Discard",
            cancelLabel: "Keep editing",
            danger: true,
        });
        if (!confirmed) {
            return;
        }

        try {
            await fetch(`/documents/${documentPath}?discard-draft`, {
                method: "POST",
                headers: { "Content-Type": "application/x-www-form-urlencoded" },
                body: "",
            });
        } finally {
            window.location.href = `/documents/${documentPath}`;
        }
    }

    /**
     * Publishes the staged edit (RFC-0032): posts the current document (and image metadata, as autosave does)
     * to `?publish`, which commits it to the tree and clears the draft, then navigates to the read view.
     */
    private async publishDocument(documentPath: string): Promise<void> {
        const parameters: Record<string, string> = { markdown: this.documentMarkdown() };
        this.attachImageMetadata(parameters);

        try {
            await fetch(`/documents/${documentPath}?publish`, {
                method: "POST",
                headers: { "Content-Type": "application/x-www-form-urlencoded" },
                body: new URLSearchParams(parameters).toString(),
            });
        } finally {
            window.location.href = `/documents/${documentPath}`;
        }
    }

    /** The metadata-pane panel linking to the page's revision history (RFC-0032), tree mode only. */
    private createHistoryPanel(): HTMLElement {
        const documentPath = this.getAttribute("data-document") ?? "";
        const panel = document.createElement("aside");
        panel.className = "markdown-editor__metadata-panel markdown-editor__history-panel";

        const heading = document.createElement("h2");
        heading.className = "markdown-editor__metadata-heading";
        heading.textContent = "History";

        const link = document.createElement("a");
        link.className = "markdown-editor__history-link";
        link.href = `/documents/${documentPath}?history`;
        link.textContent = "Revision history";

        panel.append(heading, link);
        return panel;
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
        bar.addEventListener("command-insert-attachment", (): void => {
            this.openFilePicker("file");
        });
        bar.addEventListener("command-structure", (event: Event): void => {
            this.toggleStructure((event as CustomEvent<CommandStructureEventDetail>).detail.style);
        });
        bar.addEventListener("command-insert-structure", (event: Event): void => {
            const detail = (event as CustomEvent<CommandInsertStructureEventDetail>).detail;
            this.insertStructure(detail.kind, detail.admonitionKind);
        });
        bar.addEventListener("command-badge", (event: Event): void => {
            this.applyBadge((event as CustomEvent<CommandBadgeEventDetail>).detail.value);
        });

        return bar;
    }

    /**
     * Applies, recolours, or removes the badge on the selection (RFC-0021). In the visual editor it sets or
     * unsets the badge mark; in source mode it wraps the selection as `` `selection`{.badge.<colour>} ``
     * (removal is visual-only, since stripping the source form is ambiguous).
     */
    private applyBadge(value: string): void {
        if (this.shouldUseSourceCommands()) {
            if (value !== "remove" && this.sourceEditor?.applyBadge(value)) {
                this.handleSourceInput();
            }

            return;
        }

        const applied = value === "remove" ? this.visualEditor?.removeBadge() : this.visualEditor?.applyBadge(value);

        if (applied) {
            this.handleVisualInput();
        }
    }

    /**
     * Inserts a block construct (table, callout, collapsible). In the visual editor it uses the dedicated
     * Tiptap commands; in the source editor it inserts the equivalent Markdown (a GFM table skeleton, a
     * `> [!NOTE]` alert, or an mkdocs `??? note` collapsible) at the caret.
     */
    private insertStructure(kind: InsertStructureKind, admonitionKind?: string): void {
        if (this.shouldUseSourceCommands()) {
            if (this.sourceEditor?.insertMarkdown(structureMarkdown(kind, admonitionKind))) {
                this.handleSourceInput();
            }

            return;
        }

        const callout = (admonitionKind ?? "note") as AdmonitionKind;
        const inserted =
            kind === "table"
                ? this.visualEditor?.insertTable()
                : kind === "admonition"
                  ? this.visualEditor?.insertAdmonition(callout)
                  : this.visualEditor?.insertCollapsible("note");

        if (inserted) {
            this.handleVisualInput();
        }
    }

    /** Creates the document name label shown in the editor top bar. */
    private createDocumentName(): HTMLElement {
        const nav = document.createElement("nav");
        nav.className = "markdown-editor__document-name";
        nav.setAttribute("aria-label", "Breadcrumb");

        const crumbs = parseBreadcrumbs(this.getAttribute("data-breadcrumbs"));

        if (crumbs.length === 0) {
            // No breadcrumb trail (a non-tree document): fall back to the filename.
            const fileName = documentFileName(this.getAttribute("data-document") ?? this.getAttribute("src"));
            nav.textContent = fileName ?? "";
            nav.hidden = fileName === null;

            return nav;
        }

        crumbs.forEach((crumb: Breadcrumb, index: number): void => {
            if (index > 0) {
                const separator = document.createElement("span");
                separator.className = "markdown-editor__crumb-separator";
                separator.textContent = "/";
                separator.setAttribute("aria-hidden", "true");
                nav.append(separator);
            }

            nav.append(this.createCrumb(crumb));
        });

        return nav;
    }

    /** Builds one breadcrumb: a link for an ancestor folder, or plain text for the current page. */
    private createCrumb(crumb: Breadcrumb): HTMLElement {
        if (crumb.href === undefined) {
            const current = document.createElement("span");
            current.className = "markdown-editor__crumb markdown-editor__crumb--current";
            current.setAttribute("aria-current", "page");
            current.textContent = crumb.label;

            return current;
        }

        const link = document.createElement("a");
        link.className = "markdown-editor__crumb";
        link.href = crumb.href;
        link.textContent = crumb.label;

        return link;
    }

    /** Creates the editor view mode radio group. */
    private createModeGroup(): HTMLElement {
        const group = document.createElement("wa-radio-group");
        group.className = "markdown-editor__mode-group";
        group.setAttribute("aria-label", "Editor view mode");
        group.setAttribute("orientation", "horizontal");
        group.setAttribute("size", "s");
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

    /** Creates the editing-column width radio group. */
    private createWidthGroup(): HTMLElement {
        const group = document.createElement("wa-radio-group");
        group.className = "markdown-editor__width-group";
        group.setAttribute("aria-label", "Editor width");
        group.setAttribute("orientation", "horizontal");
        group.setAttribute("size", "s");
        group.append(...bodyWidths.map((width): HTMLElement => this.createWidthOption(width.value, width.label)));
        group.addEventListener("change", (): void => {
            // The width is locked to Full in split (the control is shown but inert there), so ignore changes.
            if (this.mode === "split") {
                return;
            }

            const value = elementValue(group);

            if (isBodyWidth(value) && value !== this.bodyWidth) {
                this.bodyWidth = value;
                writeStoredPreference(bodyWidthStorageKey, value);
                this.applyBodyWidth();
                this.updateToolbarState();
            }
        });

        return group;
    }

    /** Creates one editing-column width radio option with a text label. */
    private createWidthOption(value: BodyWidth, label: string): HTMLElement {
        const option = document.createElement("wa-radio");
        option.className = "markdown-editor__width-option";
        option.textContent = label;
        option.setAttribute("appearance", "button");
        option.setAttribute("aria-label", `${label} width`);
        option.setAttribute("value", value);

        return option;
    }

    /** Resolves the initial editing-column width: stored preference, else the narrow default. */
    private editorBodyWidth(): BodyWidth {
        const stored = readStoredPreference(bodyWidthStorageKey);

        return isBodyWidth(stored) ? stored : "narrow";
    }

    /**
     * Applies the editing-column width as a `data-body-width` attribute the stylesheet keys off. Changing
     * the width resizes only the editing column; the top bar is capped at the "medium" width independently, so
     * its controls never shift. The width is a client preference (localStorage), like the colour scheme.
     */
    private applyBodyWidth(): void {
        this.setAttribute("data-body-width", this.effectiveBodyWidth());
    }

    /**
     * The width preset actually applied. Split always uses the full width (the two panes need the room), so
     * the control shows "Full" and is locked there; the chosen single-column preset is remembered for the
     * visual and Markdown views.
     */
    private effectiveBodyWidth(): BodyWidth {
        return this.mode === "split" ? "full" : this.bodyWidth;
    }

    /** Creates the editor theme radio group. */
    private createThemeGroup(): HTMLElement {
        const group = document.createElement("wa-radio-group");
        group.className = "markdown-editor__theme-group";
        group.setAttribute("aria-label", "Editor colour theme");
        group.setAttribute("orientation", "horizontal");
        group.setAttribute("size", "s");
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
        dropdown.setAttribute("size", "s");

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
        // Workbench stacks the mode and width radio groups vertically for its left rail; the other themes
        // keep them horizontal in the top toolbar. Orientation is a Web Awesome attribute, so it is toggled
        // here (on theme change, no rebuild) rather than in CSS.
        const orientation = themeUsesWorkbenchRail(this.visualTheme) ? "vertical" : "horizontal";
        this.modeGroup?.setAttribute("orientation", orientation);
        this.widthGroup?.setAttribute("orientation", orientation);
        this.relocateNotices();
        this.updateBubbleToolbar();
    }

    /**
     * Keeps the single notification area in the right place: the status row under Workbench (so messages show
     * in the status bar), and the footer above the command bar otherwise. In the read view the footer is
     * hidden, so notices are lifted to a top-level child there -- the create flow (RFC-0026) runs in both views
     * and its errors must stay visible.
     */
    private relocateNotices(): void {
        if (!this.notices || !this.footer) {
            return;
        }

        if (themeUsesWorkbenchRail(this.visualTheme) || this.isReadonly()) {
            if (this.notices.parentElement !== this) {
                this.append(this.notices);
            }
        } else if (this.notices.parentElement !== this.footer) {
            this.footer.insertBefore(this.notices, this.commandBar);
        }
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

    /** Creates the dismissible catch-all error banner (RFC-0022); hidden until a failure surfaces. */
    private createErrorBanner(): HTMLDivElement {
        const banner = document.createElement("div");
        banner.className = "markdown-editor__error-banner";
        banner.setAttribute("role", "alert");
        banner.hidden = true;

        const message = document.createElement("span");
        message.className = "markdown-editor__error-banner-message";
        message.textContent = "Something went wrong in the editor. Your last saved version is safe.";

        const dismiss = document.createElement("button");
        dismiss.type = "button";
        dismiss.className = "markdown-editor__error-banner-dismiss";
        dismiss.textContent = "Dismiss";
        dismiss.setAttribute("aria-label", "Dismiss error");
        dismiss.addEventListener("click", (): void => {
            banner.hidden = true;
        });

        banner.append(message, dismiss);

        return banner;
    }

    /** Surfaces an unexpected failure to the user and logs the underlying error to the console. */
    private showErrorBanner(error: unknown, kind: ClientErrorKind = "error"): void {
        console.error(error);
        this.clientErrorReporter.report(error, kind);

        if (!this.errorBanner) {
            return;
        }

        // Attach on demand if a failure happens before initialise attaches it (e.g. loadMarkdown rejecting):
        // into the notification area if it exists yet, else directly onto the host as a fallback.
        if (!this.errorBanner.isConnected) {
            (this.notices ?? this).append(this.errorBanner);
        }

        this.errorBanner.hidden = false;
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
        bubble.addEventListener("command-structure", (event: Event): void => {
            this.toggleStructure((event as CustomEvent<CommandStructureEventDetail>).detail.style);
            this.updateBubbleToolbar();
        });
        bubble.addEventListener("command-badge", (event: Event): void => {
            this.applyBadge((event as CustomEvent<CommandBadgeEventDetail>).detail.value);
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
        // Callout opens a submenu of its kinds so Studio -- which has no command bar -- can insert any callout
        // from the slash menu. Inline marks (Badge, bold, etc.) are not block inserts, so they live on the
        // selection bubble toolbar instead, not here.
        this.slashRoot = [
            { label: "Heading 1", run: (): void => this.applyBlockStyle("heading-1") },
            { label: "Heading 2", run: (): void => this.applyBlockStyle("heading-2") },
            { label: "Heading 3", run: (): void => this.applyBlockStyle("heading-3") },
            { label: "Heading 4", run: (): void => this.applyBlockStyle("heading-4") },
            { label: "Heading 5", run: (): void => this.applyBlockStyle("heading-5") },
            { label: "Heading 6", run: (): void => this.applyBlockStyle("heading-6") },
            { label: "Bullet list", run: (): void => this.toggleStructure("bullet-list") },
            { label: "Numbered list", run: (): void => this.toggleStructure("ordered-list") },
            { label: "Quote", run: (): void => this.toggleStructure("blockquote") },
            { label: "Code block", run: (): void => this.toggleStructure("code-block") },
            {
                label: "Callout",
                children: ADMONITION_KINDS.map((kind) => ({
                    label: admonitionTitle(kind),
                    run: (): void => this.insertAdmonition(kind),
                })),
            },
            { label: "Collapsible", run: (): void => this.insertCollapsible("note") },
            { label: "Mermaid diagram", run: (): void => this.insertMermaid() },
            { label: "Table", run: (): void => this.insertTable() },
            { label: "Image", run: (): void => this.openFilePicker("image") },
            { label: "File", run: (): void => this.openFilePicker("file") },
        ];
        this.slashStack = [];
        this.slashCommands = this.slashRoot;
        menu.items = this.slashItemLabels();
        menu.addEventListener("slash-select", (event: Event): void => {
            this.selectSlashItem((event as CustomEvent<SlashSelectEventDetail>).detail.index);
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

    /** Hides the slash menu, removes its keyboard navigation, and resets to the root level for the next open. */
    private closeSlashMenu(): void {
        this.removeEventListener("keydown", this.handleSlashKeydown, true);

        if (this.slashMenu) {
            this.slashMenu.hidden = true;
        }

        this.slashIndex = 0;

        if (this.slashStack.length > 0) {
            this.slashStack = [];
            this.slashCommands = this.slashRoot;

            if (this.slashMenu) {
                this.slashMenu.items = this.slashItemLabels();
            }
        }
    }

    /** Reflects the highlighted slash command onto the menu items. */
    private highlightSlashItem(): void {
        if (this.slashMenu) {
            this.slashMenu.activeIndex = this.slashIndex;
            this.slashMenu.flush();
        }
    }

    /** The display labels for the current menu level; group entries carry a trailing chevron affordance. */
    private slashItemLabels(): string[] {
        return this.slashCommands.map((command) => (command.children ? `${command.label} ›` : command.label));
    }

    /** Runs a leaf command, opens a group's submenu, or steps back a level -- from a click or from Enter. */
    private selectSlashItem(index: number): void {
        const command = this.slashCommands[index];

        if (!command) {
            return;
        }

        if (command.back) {
            this.exitSlashSubmenu();
        } else if (command.children) {
            this.enterSlashSubmenu(command.children);
        } else if (command.run) {
            this.runSlashCommand(command.run);
        }
    }

    /** Opens a submenu: shows its children beneath a Back entry, highlighted from the top. */
    private enterSlashSubmenu(children: SlashCommand[]): void {
        this.slashStack.push(this.slashCommands);
        this.slashCommands = [{ label: "‹ Back", back: true }, ...children];
        this.slashIndex = 0;
        this.refreshSlashMenu();
    }

    /** Returns to the parent menu level. */
    private exitSlashSubmenu(): void {
        const parent = this.slashStack.pop();

        if (!parent) {
            return;
        }

        this.slashCommands = parent;
        this.slashIndex = 0;
        this.refreshSlashMenu();
    }

    /** Repaints the menu for the current level and repositions it against the caret (its size just changed). */
    private refreshSlashMenu(): void {
        if (!this.slashMenu) {
            return;
        }

        this.slashMenu.items = this.slashItemLabels();
        this.highlightSlashItem();
        const caret = this.visualEditor?.slashCaretRect() ?? this.activeEditPaneRect();

        if (caret) {
            this.positionOverlay(this.slashMenu, caret);
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
        button.setAttribute("size", "s");
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

        this.buildingEditors = true;
        try {
            this.buildEditors();
        } finally {
            this.buildingEditors = false;
        }
    }

    /** (Re)builds the editor panes for the current mode. Wrapped by {@link renderMode}'s dirty-suppression. */
    private buildEditors(): void {
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
                { editable: !this.isReadonly() },
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
                { preserveRawHtml: this.isTreeMode(), editable: !this.isReadonly() },
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
        // An explicit ?mode= (reflected onto the attribute) always wins. Otherwise the last mode the user
        // chose is restored (so toggling edit/view -- a full navigation -- keeps the selected mode rather
        // than snapping back to the theme's default), then the theme's first-visit default, then visual.
        const mode = this.getAttribute("mode");

        if (mode === "source" || mode === "split" || mode === "visual") {
            return mode;
        }

        const stored = readStoredPreference(modeStorageKey);

        if (stored !== null && isEditorMode(stored)) {
            return stored;
        }

        return themeDefaultMode(this.visualTheme) ?? "visual";
    }

    /** Whether the editor is serving a document from the filesystem tree (set by the server). */
    private isTreeMode(): boolean {
        return this.getAttribute("data-document-mode") === "tree";
    }

    /** Whether the document is shown read-only (the rendered reading view, RFC-0020); set by the server. */
    private isReadonly(): boolean {
        return this.hasAttribute("data-readonly");
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

    /** The full document to persist: the editor body with the preserved frontmatter re-attached. */
    public documentMarkdown(): string {
        return joinFrontmatter(this.frontmatter, this.toMarkdown());
    }

    /** Replaces the current Markdown document and refreshes the active editor. */
    public setMarkdown(markdown: string): void {
        const split = splitFrontmatter(markdown);
        this.frontmatter = split.frontmatter;
        this.markdown = split.body;
        this.visualEditorChanged = false;

        if (this.sourceEditor) {
            this.sourceEditor.setMarkdown(this.markdown);
        }

        if (this.visualEditor) {
            this.visualEditor.setMarkdown(this.markdown);
        }
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

    /** Inserts a Mermaid diagram code block at the current visual selection (RFC-0033). */
    private insertMermaid(): void {
        if (this.visualEditor?.insertMermaid()) {
            this.handleVisualInput();
        }
    }

    /** Opens the native file picker, limiting it to inline image types when an image was requested. */
    private openFilePicker(kind: "image" | "file"): void {
        if (!this.fileInput) {
            return;
        }

        this.fileInput.accept = kind === "image" ? "image/png,image/jpeg,image/gif,image/webp" : "";
        this.fileInput.click();
    }

    /**
     * Uploads each file in turn, inserting its Markdown reference at the caret on success and surfacing a
     * dismissable message (inserting nothing) on failure. An "Uploading…" status shows while in flight.
     */
    private async uploadFiles(files: File[]): Promise<void> {
        const endpoint = this.uploadEndpoint();

        for (const file of files) {
            this.showUploadNotice(`Uploading ${file.name}…`, false);

            try {
                const url = await uploadAttachment(file, endpoint);
                this.insertUpload(file, url);
                if (this.isTreeMode() && !isInlineImage(file)) {
                    this.attachmentPanel?.add({ name: file.name, localPath: url });
                }
                this.hideUploadNotice();
            } catch (error: unknown) {
                this.showUploadNotice(`${file.name}: ${errorMessage(error)}`, true);
            }
        }
    }

    /**
     * The upload endpoint: in tree mode the editing document's peer-`assets/` endpoint (which returns a
     * page-relative URL the editor inserts as `assets/<name>`); otherwise the content-addressed store.
     */
    private uploadEndpoint(): string {
        if (this.isTreeMode()) {
            return `/documents/${this.getAttribute("data-document") ?? ""}?asset`;
        }

        return "/attachments";
    }

    /** Inserts an uploaded file's Markdown at the caret: an inline image, or a download link otherwise. */
    private insertUpload(file: File, url: string): void {
        if (this.shouldUseSourceCommands()) {
            if (this.sourceEditor?.insertMarkdown(attachmentMarkdown(file, url))) {
                this.handleSourceInput();
            }

            return;
        }

        const inserted = isInlineImage(file)
            ? this.visualEditor?.insertImage(url, file.name)
            : this.visualEditor?.insertFileLink(url, file.name);

        if (inserted) {
            this.handleVisualInput();
        }
    }

    /** Inserts a Markdown link to an attachment (from the metadata panel) at the caret, in either pane. */
    private insertAttachmentLink(attachment: PanelAttachment): void {
        if (this.shouldUseSourceCommands()) {
            if (this.sourceEditor?.insertMarkdown(attachmentLinkMarkdown(attachment))) {
                this.handleSourceInput();
            }

            return;
        }

        if (this.visualEditor?.insertFileLink(attachment.localPath, attachment.name)) {
            this.handleVisualInput();
        }
    }

    /** Accepts attachments dragged from the metadata panel onto the editor body, inserting a link at the caret. */
    private enableAttachmentDrop(target: HTMLElement): void {
        target.addEventListener("dragover", (event: DragEvent): void => {
            if (event.dataTransfer?.types.includes(ATTACHMENT_DRAG_TYPE)) {
                event.preventDefault();
            }
        });
        target.addEventListener("drop", (event: DragEvent): void => {
            const payload = event.dataTransfer?.getData(ATTACHMENT_DRAG_TYPE);
            if (!payload) {
                return;
            }

            event.preventDefault();
            const [attachment] = parseEmbeddedAttachments(`[${payload}]`);
            if (attachment) {
                this.insertAttachmentLink(attachment);
            }
        });
    }

    /** Shows the upload status (or error) notice with the given message. */
    private showUploadNotice(message: string, isError: boolean): void {
        if (!this.uploadNotice) {
            return;
        }

        this.uploadNotice.textContent = message;
        this.uploadNotice.classList.toggle("markdown-editor__upload-notice--error", isError);
        this.uploadNotice.hidden = false;
    }

    /** Hides the upload status notice. */
    private hideUploadNotice(): void {
        if (!this.uploadNotice) {
            return;
        }

        this.uploadNotice.textContent = "";
        this.uploadNotice.hidden = true;
    }

    /** Checks whether toolbar commands should target the source editor. */
    private shouldUseSourceCommands(): boolean {
        return Boolean(this.sourceEditor && (!this.visualEditor || this.activePane === "source"));
    }

    /** Switches the active editor mode, carrying the current Markdown across. */
    private switchMode(mode: EditorMode): void {
        this.markdown = this.toMarkdown();
        this.mode = mode;
        this.setAttribute("mode", mode);
        // Persist the choice so the next load (e.g. after an edit/view toggle) restores it.
        writeStoredPreference(modeStorageKey, mode);
        this.applyBodyWidth();
        this.renderMode();
        this.updateToolbarState();
        this.updateCursorPosition();
    }

    /** Handles source editor edits and synchronises any visual split pane. */
    private handleSourceInput(): void {
        if (this.syncingEditors || this.buildingEditors) {
            return;
        }

        const markdown = this.toMarkdown();

        this.syncVisualEditor(markdown);
        this.dispatchMarkdownChange(markdown);
    }

    /** Handles visual editor edits and synchronises any source split pane. */
    private handleVisualInput(): void {
        if (this.syncingEditors || this.buildingEditors) {
            return;
        }

        const markdown = this.visualEditor?.toMarkdown() ?? this.markdown;

        this.visualEditorChanged = true;
        this.syncSourceEditor(markdown);
        this.dispatchMarkdownChange(markdown);
        this.updateTableControls();
    }

    /** Records a valid Markdown change and notifies htmx autosave listeners. */
    private dispatchMarkdownChange(markdown: string): void {
        this.markdown = markdown;
        this.hasUnpublishedChanges = true;
        this.internals?.setFormValue(this.documentMarkdown());
        this.saveController?.markDirty();
        this.updateWordCount();
        this.updateTableOfContents();
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

    /**
     * In tree mode, carries each page-relative image's short_title (its alt text, else its filename) into
     * the save as indexed form fields, so the server syncs the page's `images.yaml` (RFC-0019, ADR-049).
     * The server reads `image_count` and the `image_path_<i>`/`image_title_<i>` pairs. A no-op outside tree
     * mode (the flat store has no sidecar metadata) and when the document has no page-relative images.
     */
    private attachImageMetadata(parameters: Record<string, string>): void {
        if (!this.isTreeMode()) {
            return;
        }

        const titles = imageShortTitles(this.toMarkdown());
        parameters["image_count"] = String(titles.length);
        titles.forEach((entry, index): void => {
            parameters[`image_path_${index}`] = entry.localPath;
            parameters[`image_title_${index}`] = entry.shortTitle;
        });
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
            const htmxEvent = event as HtmxConfigRequestEvent;

            // Persist the full document (frontmatter re-attached); track save state against the editor body,
            // which is what the save controller's baseline getter returns.
            htmxEvent.detail.parameters["markdown"] = this.documentMarkdown();
            this.attachImageMetadata(htmxEvent.detail.parameters);
            this.saveController?.markSubmitted(this.toMarkdown());
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

        if (this.widthGroup) {
            const width = this.effectiveBodyWidth();
            setElementValue(this.widthGroup, width);
            this.widthGroup.setAttribute("value", width);

            for (const option of this.widthGroup.querySelectorAll("wa-radio")) {
                if (option.getAttribute("value") === width) {
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
        if (this.wordReadout) {
            this.wordReadout.textContent = wordCountLabel(this.markdown);
        }
    }

    /**
     * Updates the status-bar caret-position readout from the source editor (the only pane with a line/column
     * notion). Cleared when no source pane is shown, so visual-only mode carries the word count alone.
     */
    private updateCursorPosition(): void {
        if (!this.cursorReadout) {
            return;
        }

        const position = this.sourceEditor?.cursorPosition() ?? null;
        this.cursorReadout.textContent = position ? `ln ${position.line}, col ${position.column}` : "";
    }

    /**
     * Regenerates the contents panel from the current Markdown. The sidebar collapses when there is nothing
     * to show (no headings and, outside the document tree, no attachments panel).
     */
    private updateTableOfContents(): void {
        if (!this.tocPanel) {
            return;
        }

        const entries = documentHeadings(this.markdown);
        this.tocPanel.setEntries(entries);

        if (this.sidebar) {
            this.sidebar.hidden = !this.isTreeMode() && entries.length === 0;
        }
    }

    /**
     * Builds the page-title field shown above the editing pane. In the read view it is a read-only heading
     * (hidden when the page has no title); when editable it is an input bound to the frontmatter `name`.
     */
    private createTitleField(): HTMLElement {
        const title = frontmatterName(this.frontmatter);

        if (this.isReadonly()) {
            const display = document.createElement("h1");
            display.className = "markdown-editor__title markdown-editor__title--display";
            display.textContent = title ?? "";
            display.hidden = title === null || title === "";

            return display;
        }

        const input = document.createElement("input");
        input.type = "text";
        input.className = "markdown-editor__title markdown-editor__title--input";
        input.value = title ?? "";
        input.placeholder = "Title";
        input.setAttribute("aria-label", "Page title");
        input.addEventListener("input", (): void => this.handleTitleChange(input.value));

        return input;
    }

    /** Writes an edited title back to the frontmatter `name` and persists it (the body is unchanged). */
    private handleTitleChange(title: string): void {
        this.frontmatter = setFrontmatterName(this.frontmatter, title);
        this.dispatchMarkdownChange(this.markdown);
    }

    /** Scrolls the active pane to the n-th heading (the contents panel's click target). */
    private scrollToHeading(index: number): void {
        if (this.visualEditor) {
            this.visualEditor.scrollToHeading(index);
        } else {
            this.sourceEditor?.scrollToHeading(index);
        }
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

/** Whether a drag carries files (so the editor should claim the drop rather than the browser). */
function dragHasFiles(transfer: DataTransfer | null): boolean {
    return transfer ? Array.from(transfer.types).includes("Files") : false;
}

/** Extracts the files from a drag or clipboard transfer (empty when it carries none). */
function filesFromDataTransfer(transfer: DataTransfer | null): File[] {
    return transfer ? Array.from(transfer.files) : [];
}

/** Checks that a toolbar value is a supported visual block style. */
function isVisualBlockStyle(style: string): style is VisualBlockStyle {
    return style === "paragraph" || /^heading-[1-6]$/.test(style);
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
/** Parses JSON, returning null on malformed input (for tolerant response handling). */
function safeJson(text: string): unknown {
    try {
        return JSON.parse(text);
    } catch {
        return null;
    }
}

/** The message shown when a structural-operation request cannot reach the server. */
const NETWORK_ERROR = "Couldn’t reach the server.";

/**
 * Runs a structural-operation request (undo/restore/replay) and normalises it to an OpResult: the
 * ok message on success, the response body (or a fallback) on an error status, and the network
 * message when the fetch itself throws — so a failure always surfaces rather than being swallowed.
 */
async function opRequest(
    url: string,
    init: RequestInit,
    okMessage: string,
    failMessage: string,
): Promise<{ ok: boolean; message: string }> {
    try {
        const response = await fetch(url, init);
        if (response.ok) {
            return { ok: true, message: okMessage };
        }
        const body = (await response.text()).trim();
        return { ok: false, message: body || failMessage };
    } catch {
        return { ok: false, message: NETWORK_ERROR };
    }
}

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
/**
 * Whether a global error message is benign browser noise the error banner should ignore. The "ResizeObserver
 * loop" notification is the notable case: browsers emit it (with no error object) when a resize handler
 * causes further layout, which is normal for dynamic editor chrome; surfacing it would recur and block
 * dismissal.
 */
function isIgnorableGlobalError(message: string): boolean {
    return /ResizeObserver loop/i.test(message);
}

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

/** The Markdown a block-insert command writes in source mode: a GFM table, a GFM alert, or an mkdocs collapsible. */
function structureMarkdown(kind: InsertStructureKind, admonitionKind?: string): string {
    if (kind === "table") {
        return "| Column | Column |\n| --- | --- |\n| Cell | Cell |\n";
    }

    if (kind === "admonition") {
        return `> [!${(admonitionKind ?? "note").toUpperCase()}]\n> Text\n`;
    }

    return '??? note "Title"\n    Text\n';
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
