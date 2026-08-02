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
import {
    type ChromeDropdownElement,
    type ChromeSegmentElement,
    chromeAlertEl,
    chromeButtonEl,
    chromeDropdownEl,
    chromeIconEl,
    chromeLinkEl,
    chromeSegmentEl,
    initBasecoat,
    NETWORK_ERROR,
} from "./chrome.js";
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

type EditorMode = "visual" | "source" | "split";
type EditorTheme = "light" | "dark" | "match-system";
type BodyWidth = "narrow" | "medium" | "full";
type VisualTheme = "shadcn" | "studio";
type ActivePane = "source" | "visual";

const visualThemeStorageKey = "editor-theme";
const colorSchemeStorageKey = "editor-color-scheme";
const bodyWidthStorageKey = "editor-body-width";
const modeStorageKey = "editor-mode";
const sidebarCollapsedStorageKey = "editor-sidebar-collapsed";

/** The narrow-viewport disclosure's label above the first heading, where no section is current. */
const SIDEBAR_DISCLOSURE_FALLBACK = "Contents";

/** How often scrolling may re-read the heading positions to rename the disclosure trigger. */
const sidebarLabelThrottleMilliseconds = 100;

/** Below this width the navigation tree is a panel, not a column. Kept in step with the stylesheet. */
const navPanelMediaQuery = "(max-width: 53rem)";

/** The selectable editing-column widths, in toolbar order; "narrow" is the default. Icons read as
    increasing column width (a portrait, a square, a landscape rectangle). */
const bodyWidths: { value: BodyWidth; label: string; icon: string }[] = [
    { value: "narrow", label: "Narrow", icon: "rectangle-vertical" },
    { value: "medium", label: "Medium", icon: "square" },
    { value: "full", label: "Full", icon: "rectangle-horizontal" },
];

/** Narrows an arbitrary string to a known editing-column width. */
function isBodyWidth(value: string | null): value is BodyWidth {
    return value !== null && bodyWidths.some((width) => width.value === value);
}

/** The selectable visual themes (RFC-0035): the default shadcn look, and Studio,
 * which keeps the same look but swaps the persistent command bar for the bubble
 * toolbar and slash menu. */
const visualThemes: { value: VisualTheme; label: string }[] = [
    { value: "shadcn", label: "Shadcn" },
    { value: "studio", label: "Studio" },
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

/** Web component that edits one Markdown document, saving through its own fetch autosave (RFC-0036). */
/** The autosave debounce: a pause this long after the last change saves (was hx-trigger delay:2s). */
const autosaveDebounceMilliseconds = 2000;

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
    private modeGroup: ChromeSegmentElement | null = null;
    private widthGroup: ChromeSegmentElement | null = null;
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
    private saveError: HTMLElement | null = null;
    private saveErrorMessage: HTMLElement | null = null;
    private errorBanner: HTMLDivElement | null = null;
    /** The single notification area (save + client errors, upload notices); relocated per theme. */
    private notices: HTMLDivElement | null = null;
    private footer: HTMLDivElement | null = null;
    private readonly clientErrorReporter = new ClientErrorReporter();
    private saveController: SaveStateController | null = null;
    private autosaveHandle: number | null = null;
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
    private themeGroup: ChromeSegmentElement | null = null;
    private themeDropdown: ChromeDropdownElement | null = null;
    private visualTheme: VisualTheme = "shadcn";
    /** A faster (200 ms) tooltip just for the navigation tree's truncated labels (RFC-0026). */
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
    private uploadNoticeMessage: HTMLElement | null = null;
    private uploadNoticeDestructive: ((on: boolean) => void) | null = null;
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
    /** The narrow-viewport metadata-panel trigger, and its document-level dismiss handlers. */
    private sidebarDisclosure: HTMLButtonElement | null = null;
    private sidebarDisclosureLabel: HTMLSpanElement | null = null;
    private navDisclosure: HTMLButtonElement | null = null;
    private appearanceTrigger: HTMLButtonElement | null = null;
    private dismissSidebarOnClick: ((event: MouseEvent) => void) | null = null;
    private dismissSidebarOnKey: ((event: KeyboardEvent) => void) | null = null;
    private trackSidebarOnScroll: (() => void) | null = null;
    private trackSidebarOnResize: (() => void) | null = null;
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
        this.saveController?.dispose();
        if (this.autosaveHandle !== null) {
            window.clearTimeout(this.autosaveHandle);
            this.autosaveHandle = null;
        }
        this.sourceEditor?.destroy();
        this.sourceEditor = null;
        this.visualEditor?.destroy();
        this.visualEditor = null;
        this.topBarResizeObserver?.disconnect();
        this.topBarResizeObserver = null;
        if (this.dismissSidebarOnClick !== null) {
            document.removeEventListener("click", this.dismissSidebarOnClick);
            this.dismissSidebarOnClick = null;
        }
        if (this.dismissSidebarOnKey !== null) {
            document.removeEventListener("keydown", this.dismissSidebarOnKey);
            this.dismissSidebarOnKey = null;
        }
        if (this.trackSidebarOnScroll !== null) {
            window.removeEventListener("scroll", this.trackSidebarOnScroll, true);
            this.trackSidebarOnScroll = null;
        }
        if (this.trackSidebarOnResize !== null) {
            window.removeEventListener("resize", this.trackSidebarOnResize);
            this.trackSidebarOnResize = null;
        }
    }

    /**
     * The narrow-viewport disclosure for the metadata pane. Below the sidebar breakpoint the pane
     * stops being a column beside the editor (it squeezes the prose measure under ~50 characters)
     * and becomes a panel opened from this trigger, which sits in its own top-bar row under the
     * breadcrumb and search. The row is created at every width and hidden by CSS above the
     * breakpoint, so nothing has to be rebuilt on resize -- the pane itself is never moved in the
     * DOM either, only repositioned, so the contents, attachments, and history panels keep their
     * live element references.
     */
    private createSidebarDisclosure(): HTMLDivElement {
        const row = document.createElement("div");
        row.className = "markdown-editor__sidebar-row";

        const trigger = chromeButtonEl("outline", "", {
            className: "markdown-editor__sidebar-disclosure",
        });
        trigger.setAttribute("aria-expanded", "false");
        // The label is its own element so the scroll position can rewrite it without
        // disturbing the chevron, which the row pushes to the trailing edge.
        this.sidebarDisclosureLabel = document.createElement("span");
        this.sidebarDisclosureLabel.className = "markdown-editor__sidebar-disclosure-label";
        this.sidebarDisclosureLabel.textContent = SIDEBAR_DISCLOSURE_FALLBACK;
        trigger.append(this.sidebarDisclosureLabel, chromeIconEl("chevron-down"));
        trigger.addEventListener("click", (event: MouseEvent): void => {
            // Stop the document handler below from seeing this click as an outside click.
            event.stopPropagation();
            this.setSidebarDisclosureOpen(!this.hasAttribute("data-sidebar-open"));
        });
        this.sidebarDisclosure = trigger;
        row.append(trigger);
        return row;
    }

    /**
     * The rail's narrow-viewport trigger. Below the rail breakpoint the navigation tree stops being
     * a column -- collapsed it still left a gutter beside the content -- and becomes a panel opened
     * from this button, which carries the rail's own collapse glyph and sits ahead of Edit/Publish.
     * As with the metadata pane, the tree is never moved in the DOM, only repositioned, so its
     * lazy-loading, drag-and-drop, and popover wiring all keep working.
     */
    private createNavDisclosure(): HTMLButtonElement {
        const trigger = chromeButtonEl("icon", "", {
            className: "markdown-editor__nav-trigger",
            ariaLabel: "Show pages",
            tooltip: "Show pages",
        });
        trigger.setAttribute("aria-expanded", "false");
        trigger.append(chromeIconEl("panel-left"));
        trigger.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            if (this.navIsPanel()) {
                this.setNavDisclosureOpen(!this.hasAttribute("data-nav-open"));
            } else {
                // As a column the same button shows and hides the rail itself. Hidden means gone
                // from the layout, not narrowed to a stub, so no gutter is left beside the content.
                this.navTree?.toggleCollapsed();
                this.syncNavTriggerState();
            }
        });
        this.navDisclosure = trigger;
        return trigger;
    }

    /** Opens or closes the narrow-viewport navigation panel, keeping the trigger's ARIA state in step. */
    private setNavDisclosureOpen(open: boolean): void {
        this.toggleAttribute("data-nav-open", open);
        this.syncNavTriggerState();
    }

    /**
     * The trigger that collapses the presentation controls into a panel at the top right. It appears
     * when the toolbar's own column is too narrow to seat mode, width, light/dark and theme in a row,
     * which is a property of the content column rather than the viewport -- the rail's 272px means the
     * row runs out of space twice as the window narrows, once while the rail is a column and again
     * once it is gone. A container query on the toolbar is what expresses that; the breakpoint lives
     * in the stylesheet.
     */
    private createAppearanceTrigger(): HTMLButtonElement {
        const trigger = chromeButtonEl("icon", "", {
            className: "markdown-editor__appearance-trigger",
            ariaLabel: "Appearance",
            tooltip: "Appearance",
        });
        trigger.setAttribute("aria-expanded", "false");
        trigger.append(chromeIconEl("sliders-horizontal"));
        trigger.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            this.setAppearanceOpen(!this.hasAttribute("data-appearance-open"));
        });
        this.appearanceTrigger = trigger;
        return trigger;
    }

    /** Opens or closes the presentation panel, pinning it under its trigger while open. */
    private setAppearanceOpen(open: boolean): void {
        this.toggleAttribute("data-appearance-open", open);
        this.appearanceTrigger?.setAttribute("aria-expanded", open ? "true" : "false");
    }

    /** Whether the viewport is below the rail breakpoint, where the tree is a panel rather than a column. */
    private navIsPanel(): boolean {
        return window.matchMedia(navPanelMediaQuery).matches;
    }

    /**
     * Points the rail trigger at whichever state it currently drives: the overlay panel below the
     * rail breakpoint, the rail's own visibility above it.
     */
    private syncNavTriggerState(): void {
        if (this.navDisclosure === null) {
            return;
        }
        const shown = this.navIsPanel() ? this.hasAttribute("data-nav-open") : !(this.navTree?.isCollapsed() ?? false);
        this.navDisclosure.setAttribute("aria-expanded", shown ? "true" : "false");
        const label = shown ? "Hide pages" : "Show pages";
        this.navDisclosure.setAttribute("aria-label", label);
        this.navDisclosure.setAttribute("data-tooltip", label);
    }

    /** Opens or closes the narrow-viewport metadata panel, keeping the trigger's ARIA state in step. */
    private setSidebarDisclosureOpen(open: boolean): void {
        this.toggleAttribute("data-sidebar-open", open);
        this.sidebarDisclosure?.setAttribute("aria-expanded", open ? "true" : "false");
        if (open) {
            this.pinSidebarPanel();
        }
    }

    /**
     * Pins the metadata panel under its trigger, in fixed viewport coordinates. The trigger rides
     * the sticky top bar while the workspace scrolls away beneath it, so a panel positioned against
     * the workspace lands off-screen above the fold as soon as the page is scrolled -- it has to be
     * anchored to the trigger, not to the document. Matches the trigger's box so the panel spans
     * the content column.
     */
    private pinSidebarPanel(): void {
        if (this.sidebar === null || this.sidebarDisclosure === null) {
            return;
        }
        // Published as custom properties rather than set on the pane directly: only the
        // narrow-viewport rules read them, so nothing leaks into the wide layout, where the
        // pane is a sticky column with its own top and width.
        const rect = this.sidebarDisclosure.getBoundingClientRect();
        this.style.setProperty("--markdown-editor-sidebar-panel-top", `${Math.round(rect.bottom + 4)}px`);
        this.style.setProperty("--markdown-editor-sidebar-panel-left", `${Math.round(rect.left)}px`);
        this.style.setProperty("--markdown-editor-sidebar-panel-width", `${Math.round(rect.width)}px`);
    }

    /**
     * The rendered heading elements of the visual view, in document order. The source view is a
     * CodeMirror document with no heading elements to measure, so it reports none and the trigger
     * keeps its fallback label.
     */
    private headingElements(): HTMLElement[] {
        return [
            ...this.querySelectorAll<HTMLElement>(
                ".ProseMirror > h1, .ProseMirror > h2, .ProseMirror > h3, .ProseMirror > h4, .ProseMirror > h5, .ProseMirror > h6",
            ),
        ];
    }

    /**
     * Names the section being read on the collapsed trigger: the last heading to have passed under
     * the top bar. Above the first heading there is no such section, so the fallback label stands.
     */
    private updateSidebarDisclosureLabel(): void {
        if (this.sidebarDisclosureLabel === null) {
            return;
        }
        const cutoff = (this.sidebarDisclosure?.getBoundingClientRect().bottom ?? 0) + 4;
        const current = this.headingElements()
            .filter((heading: HTMLElement): boolean => heading.getBoundingClientRect().top <= cutoff)
            .pop();
        this.sidebarDisclosureLabel.textContent = current?.textContent?.trim() || SIDEBAR_DISCLOSURE_FALLBACK;
    }

    /** Dismisses the narrow-viewport metadata panel on an outside click or Escape. */
    private installSidebarDisclosureDismiss(): void {
        this.dismissSidebarOnClick = (event: MouseEvent): void => {
            const target = event.target as Node;
            if (this.hasAttribute("data-sidebar-open") && this.sidebar !== null && !this.sidebar.contains(target)) {
                this.setSidebarDisclosureOpen(false);
            }
            const navPanel = this.navTree?.element() ?? null;
            if (this.hasAttribute("data-nav-open") && navPanel !== null && !navPanel.contains(target)) {
                this.setNavDisclosureOpen(false);
            }
            const presentation = this.querySelector(".markdown-editor__presentation");
            if (this.hasAttribute("data-appearance-open") && presentation !== null && !presentation.contains(target)) {
                this.setAppearanceOpen(false);
            }
        };
        this.dismissSidebarOnKey = (event: KeyboardEvent): void => {
            if (event.key === "Escape" && this.hasAttribute("data-sidebar-open")) {
                this.setSidebarDisclosureOpen(false);
            }
            if (event.key === "Escape" && this.hasAttribute("data-nav-open")) {
                this.setNavDisclosureOpen(false);
            }
            if (event.key === "Escape" && this.hasAttribute("data-appearance-open")) {
                this.setAppearanceOpen(false);
            }
        };
        document.addEventListener("click", this.dismissSidebarOnClick);
        document.addEventListener("keydown", this.dismissSidebarOnKey);

        // Scroll only renames the section on the trigger; it never re-pins the panel, because the
        // trigger rides the sticky top bar and so does not move as the page scrolls. Throttled on a
        // timestamp rather than requestAnimationFrame, which is throttled to a standstill while the
        // page is hidden -- the same reason pinNavPopover positions synchronously.
        let lastLabelUpdate = 0;
        this.trackSidebarOnScroll = (): void => {
            const now = Date.now();
            if (now - lastLabelUpdate < sidebarLabelThrottleMilliseconds) {
                return;
            }
            lastLabelUpdate = now;
            this.updateSidebarDisclosureLabel();
        };
        // Resizing does move the trigger, so an open panel is re-pinned to it.
        this.trackSidebarOnResize = (): void => {
            this.updateSidebarDisclosureLabel();
            if (this.hasAttribute("data-sidebar-open")) {
                this.pinSidebarPanel();
            }
            // Crossing the rail breakpoint changes what the trigger drives.
            this.syncNavTriggerState();
        };
        window.addEventListener("scroll", this.trackSidebarOnScroll, true);
        window.addEventListener("resize", this.trackSidebarOnResize);
        this.updateSidebarDisclosureLabel();
        // The rail may start collapsed from a stored preference, so the trigger is named
        // for the state it will move to before it is ever pressed.
        this.syncNavTriggerState();
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

        // The trusted document tree may contain raw HTML (export-metadata comments, occasional
        // markup); preserve it verbatim and inert rather than throwing on it (ADR-040/041).
        // Badge lozenges (RFC-0021) ride along.
        registerExtension(rawHtmlExtension);
        registerExtension(badgeExtension);

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

        const uploadNotice = chromeAlertEl({ className: "markdown-editor__upload-notice", role: "status" });
        this.uploadNotice = uploadNotice.root;
        this.uploadNoticeMessage = uploadNotice.message;
        this.uploadNoticeDestructive = uploadNotice.setDestructive;

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
        // A collapse toggle mirroring the nav's, so the metadata pane can fold to a thin rail
        // (the state persists). panel-right reads as "the right-hand panel".
        const sidebarToggle = document.createElement("button");
        sidebarToggle.type = "button";
        sidebarToggle.className = "markdown-editor__sidebar-toggle";
        sidebarToggle.setAttribute("aria-label", "Collapse metadata panel");
        sidebarToggle.setAttribute("data-tooltip", "Collapse metadata panel");
        sidebarToggle.append(chromeIconEl("panel-right"));
        sidebarToggle.addEventListener("click", (): void => {
            const collapsed = this.sidebar?.getAttribute("data-collapsed") === "true";
            this.setSidebarCollapsed(!collapsed);
        });
        this.sidebar.append(sidebarToggle);
        this.tocPanel = new TableOfContentsPanel((index: number): void => {
            // As a narrow-viewport panel the pane covers the prose it just scrolled to, so
            // choosing a heading dismisses it. A no-op when the pane is a column.
            this.setSidebarDisclosureOpen(false);
            this.scrollToHeading(index);
        });
        this.sidebar.append(this.tocPanel.element());
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
        // The navigation tree (RFC-0026, RFC-0035): a full-height column pinned to the viewport's left edge,
        // a sibling of the content column rather than inside the centred workspace, so it reads as an app
        // sidebar (the shadcn layout) rather than sitting inside the page gutter.
        this.navTree = this.createNavTree();
        workspace.append(this.sidebar);

        // The top bar (presentation controls + breadcrumb) is one unit so it can stick to the top of the
        // viewport as a whole while the content scrolls (RFC-0026 follow-up); Workbench flattens it back to
        // two grid items with `display: contents`.
        this.topBar = document.createElement("div");
        this.topBar.className = "markdown-editor__topbar";
        // The top bar's second row: the breadcrumb on the left and the search box (RFC-0034) on the
        // right. The search results drop down over the page content (the panel blurs the page behind
        // them); the box hides itself when search is disabled, and only tree mode has an index to
        // search. Workbench places this row as its file-tab strip (grid-area tab).
        const topBarRow = document.createElement("div");
        topBarRow.className = "markdown-editor__topbar-row";
        topBarRow.append(this.documentName);
        const searchPanel = new SearchPanel();
        topBarRow.append(searchPanel.element());
        void searchPanel.connect();
        this.topBar.append(this.toolbar, topBarRow, this.createSidebarDisclosure());

        // The content column holds the top bar, the editing workspace, and the bottom bars. It is a flex
        // column beside the viewport-pinned nav; the host is a flex row of [nav, content]. The floating
        // affordances (popovers, bubble toolbar, tooltips) stay direct host children so they keep anchoring
        // to the host's positioning context.
        const contentColumn = document.createElement("div");
        contentColumn.className = "markdown-editor__content";
        contentColumn.append(this.topBar, workspace, this.footer, this.wordCount);

        this.append(
            ...(this.navTree ? [this.navTree.element()] : []),
            contentColumn,
            this.linkController.editorElement(),
            this.linkController.actionsElement(),
            this.bubbleToolbar,
            this.slashMenu,
            this.tableControls,
        );
        this.applyBodyWidth();
        this.setSidebarCollapsed(readStoredPreference(sidebarCollapsedStorageKey) === "true");
        initBasecoat();
        this.observeTopBarHeight();
        this.installSidebarDisclosureDismiss();
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
            this.configureAutosave();
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
            registerTooltip: (target: HTMLElement, text: string): void => {
                target.setAttribute("data-tooltip", text);
            },
            notify: (message: string, isError: boolean): void => this.showUploadNotice(message, isError),
            deleteNode: async (path: string): Promise<DeleteResult> => {
                try {
                    const response = await fetch(`/tree/${encodePath(path)}`, { method: "DELETE" });
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
            listMoves: async (): Promise<MoveOp[] | null> => {
                try {
                    const response = await fetch("/operations", { headers: { Accept: "application/json" } });
                    if (!response.ok) {
                        return null;
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
                    return null;
                }
            },
            listTrash: async (): Promise<TrashEntry[] | null> => {
                try {
                    const response = await fetch("/trash", { headers: { Accept: "application/json" } });
                    if (!response.ok) {
                        return null;
                    }
                    const data: unknown = safeJson(await response.text());
                    return Array.isArray(data) ? (data as TrashEntry[]) : [];
                } catch {
                    return null;
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

        // Three slots (a grid: start, centre, end): the read/edit toggle at the left, the mode and width
        // controls centred over the content, and the appearance controls at the right.
        const controls = document.createElement("div");
        controls.className = "markdown-editor__toolbar-controls";

        const startSlot = document.createElement("div");
        startSlot.className = "markdown-editor__toolbar-slot markdown-editor__toolbar-slot--start";
        // Below the rail breakpoint the navigation tree collapses to this one button, which sits
        // ahead of Edit/Publish. Built at every width and hidden by CSS above the breakpoint.
        startSlot.append(this.createNavDisclosure());
        const readEditLink = this.createReadEditLink();
        if (readEditLink) {
            startSlot.append(readEditLink);
        }

        const centreSlot = document.createElement("div");
        centreSlot.className = "markdown-editor__toolbar-slot markdown-editor__toolbar-slot--centre";
        this.modeGroup = this.createModeGroup();
        this.widthGroup = this.createWidthGroup();
        centreSlot.append(this.modeGroup, this.widthGroup);

        // The visual-theme dropdown and the light/dark appearance group travel together as one unit
        // ("appearance") at the right of the top bar.
        const appearance = document.createElement("div");
        appearance.className =
            "markdown-editor__toolbar-slot markdown-editor__toolbar-slot--end markdown-editor__appearance";
        this.themeDropdown = this.createThemeDropdown();
        appearance.append(this.themeDropdown);
        this.themeGroup = this.createThemeGroup();
        appearance.append(this.themeGroup);

        // The presentation controls (mode, width, light/dark, theme) are wrapped so a narrow
        // toolbar can lift them out as one panel. The wrapper is `display: contents` at full
        // width, so the grid still sees the centre and appearance slots as its own items and the
        // wide layout is unchanged -- nothing is re-parented when the breakpoint is crossed.
        const presentation = document.createElement("div");
        presentation.className = "markdown-editor__presentation";
        presentation.append(centreSlot, appearance);
        controls.append(startSlot, presentation, this.createAppearanceTrigger());

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
     */
    private createReadEditLink(): HTMLElement | null {
        const documentPath = this.getAttribute("data-document") ?? "";
        const group = window.document.createElement("span");
        group.className = "markdown-editor__view-toggle-group";

        if (this.isReadonly()) {
            const link = chromeLinkEl("outline", "Edit", `/documents/${documentPath}?edit`, {
                className: "markdown-editor__view-toggle",
            });
            group.append(link);

            if (this.hasAttribute("data-has-draft")) {
                const marker = window.document.createElement("span");
                marker.className = "markdown-editor__draft-marker";
                marker.textContent = "(unpublished draft)";
                group.append(marker);
            }
        } else {
            const publish = chromeButtonEl("primary", "Publish", {
                className: "markdown-editor__view-toggle markdown-editor__publish",
            });
            publish.addEventListener("click", (): void => {
                void this.publishDocument(documentPath);
            });

            const cancel = chromeButtonEl("outline", "Cancel", {
                className: "markdown-editor__view-toggle markdown-editor__cancel",
            });
            cancel.addEventListener("click", (): void => {
                void this.discardDraft(documentPath);
            });

            group.append(publish, cancel);
        }

        return group;
    }

    /**
     * Discards the staged draft (RFC-0032): a `DELETE` of the draft resource, so the page reverts to its
     * last published (committed) version, then returns to the read view. Confirms first, since it abandons
     * changes.
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
            await fetch(`/drafts/${documentPath}`, { method: "DELETE" });
        } finally {
            window.location.href = `/documents/${documentPath}`;
        }
    }

    /**
     * Publishes the staged edit (RFC-0032/0036): a `PUT` of the raw document to the page resource (which
     * commits it and clears the draft), then the image-title sidecar sync when the page has page-relative
     * images, then navigation to the read view.
     */
    private async publishDocument(documentPath: string): Promise<void> {
        try {
            await fetch(`/documents/${documentPath}`, {
                method: "PUT",
                headers: { "Content-Type": "text/markdown; charset=utf-8" },
                body: this.documentMarkdown(),
            });
            await this.syncImageTitles(documentPath);
        } finally {
            window.location.href = `/documents/${documentPath}`;
        }
    }

    /**
     * Posts the page's image short_titles to the image-titles controller (RFC-0019 fields, RFC-0036
     * endpoint) after a publish. Skipped when the page has no page-relative images.
     */
    private async syncImageTitles(documentPath: string): Promise<void> {
        const parameters: Record<string, string> = {};
        this.attachImageMetadata(parameters);

        if (parameters["image_count"] === "0") {
            return;
        }

        await fetch(`/documents/${documentPath}?image-titles`, {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams(parameters).toString(),
        });
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

    /** Creates the editor view mode segmented control. */
    private createModeGroup(): ChromeSegmentElement {
        const group = chromeSegmentEl({
            className: "markdown-editor__mode-group",
            ariaLabel: "Editor view mode",
            joined: true,
            entries: [
                { value: "visual", label: "Visual" },
                { value: "source", label: "Markdown" },
                { value: "split", label: "Split" },
            ],
        });
        group.addEventListener("change", (): void => {
            const mode = elementValue(group);

            if (isEditorMode(mode) && mode !== this.mode) {
                this.switchMode(mode);
            }
        });

        return group;
    }

    /** Creates the editing-column width segmented control. */
    private createWidthGroup(): ChromeSegmentElement {
        const group = chromeSegmentEl({
            className: "markdown-editor__width-group",
            ariaLabel: "Editor width",
            joined: true,
            entries: bodyWidths.map((width) => ({
                value: width.value,
                label: width.label,
                icon: width.icon,
                iconOnly: true,
            })),
        });
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

    /** Folds or unfolds the right-hand metadata pane to a thin rail; the choice persists. */
    private setSidebarCollapsed(collapsed: boolean): void {
        if (!this.sidebar) {
            return;
        }

        this.sidebar.setAttribute("data-collapsed", collapsed ? "true" : "false");
        const toggle = this.sidebar.querySelector(".markdown-editor__sidebar-toggle");
        toggle?.setAttribute("aria-label", collapsed ? "Expand metadata panel" : "Collapse metadata panel");
        toggle?.setAttribute("data-tooltip", collapsed ? "Expand metadata panel" : "Collapse metadata panel");
        writeStoredPreference(sidebarCollapsedStorageKey, collapsed ? "true" : "false");
    }

    /**
     * The width preset actually applied. Split always uses the full width (the two panes need the room), so
     * the control shows "Full" and is locked there; the chosen single-column preset is remembered for the
     * visual and Markdown views.
     */
    private effectiveBodyWidth(): BodyWidth {
        return this.mode === "split" ? "full" : this.bodyWidth;
    }

    /** Creates the colour-scheme segmented control (joined outline icon buttons). */
    private createThemeGroup(): ChromeSegmentElement {
        const group = chromeSegmentEl({
            className: "markdown-editor__theme-group",
            ariaLabel: "Editor colour theme",
            joined: true,
            entries: [
                { value: "light", label: "Light", icon: "sun", iconOnly: true },
                { value: "dark", label: "Dark", icon: "moon", iconOnly: true },
                { value: "match-system", label: "Match system", icon: "monitor", iconOnly: true },
            ],
        });
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

    /** Creates the visual-theme dropdown shown in the top bar. */
    private createThemeDropdown(): ChromeDropdownElement {
        return chromeDropdownEl({
            id: "editor-theme-menu",
            className: "markdown-editor__theme-dropdown",
            intent: "quiet",
            triggerLabel: themeLabel(this.visualTheme),
            triggerClassName: "markdown-editor__button markdown-editor__theme-trigger",
            ariaLabel: "Visual theme",
            items: visualThemes.map((theme) => ({ value: theme.value, label: theme.label })),
            onSelect: (value: string): void => {
                if (isVisualTheme(value)) {
                    this.setVisualTheme(value);
                }
            },
        });
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
        this.relocateNotices();
        this.updateBubbleToolbar();
    }

    /**
     * Keeps the single notification area in the right place: the footer above the command bar while
     * editing. In the read view the footer is hidden, so notices are lifted to a top-level child there --
     * the create flow (RFC-0026) runs in both views and its errors must stay visible.
     */
    private relocateNotices(): void {
        if (!this.notices || !this.footer) {
            return;
        }

        if (this.isReadonly()) {
            if (this.notices.parentElement !== this) {
                this.append(this.notices);
            }
        } else if (this.notices.parentElement !== this.footer) {
            this.footer.insertBefore(this.notices, this.commandBar);
        }
    }

    /** Resolves the initial visual theme: stored preference, then page attribute, else shadcn. */
    private editorVisualTheme(): VisualTheme {
        const stored = readStoredPreference(visualThemeStorageKey);

        if (isVisualTheme(stored)) {
            return stored;
        }

        const fromPage = document.documentElement.getAttribute("data-editor-theme");

        return isVisualTheme(fromPage) ? fromPage : "shadcn";
    }

    /** Reflects the current visual theme into the dropdown trigger and items. */
    private syncThemeDropdown(): void {
        if (!this.themeDropdown) {
            return;
        }

        this.themeDropdown.setTriggerLabel(themeLabel(this.visualTheme));
        this.themeDropdown.syncChecked(this.visualTheme);
    }

    /** Creates the save error notice shown when the last save failed. */
    private createSaveError(): HTMLElement {
        const { root, message } = chromeAlertEl({
            className: "markdown-editor__save-error",
            role: "status",
            destructive: true,
        });
        this.saveError = root;
        this.saveErrorMessage = message;

        return root;
    }

    /** Creates the dismissible catch-all error banner (RFC-0022); hidden until a failure surfaces. */
    private createErrorBanner(): HTMLDivElement {
        const { root, message, dismiss } = chromeAlertEl({
            className: "markdown-editor__error-banner",
            role: "alert",
            destructive: true,
        });
        message.textContent = "Something went wrong in the editor. Your last saved version is safe.";
        dismiss.classList.add("markdown-editor__error-banner-dismiss");
        dismiss.setAttribute("aria-label", "Dismiss error");

        return root;
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
            { label: "Horizontal rule", run: (): void => this.toggleStructure("thematic-break") },
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
                { preserveRawHtml: true, editable: !this.isReadonly() },
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

        return "visual";
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
                if (!isInlineImage(file)) {
                    this.attachmentPanel?.add({ name: file.name, localPath: url });
                }
                this.hideUploadNotice();
            } catch (error: unknown) {
                this.showUploadNotice(`${file.name}: ${errorMessage(error)}`, true);
            }
        }
    }

    /**
     * The upload endpoint: the editing document's peer-`assets/` endpoint, which returns a
     * page-relative URL the editor inserts as `assets/<name>` (RFC-0018 as amended).
     */
    private uploadEndpoint(): string {
        return `/documents/${this.getAttribute("data-document") ?? ""}?asset`;
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
        if (!this.uploadNotice || !this.uploadNoticeMessage) {
            return;
        }

        this.uploadNoticeMessage.textContent = message;
        this.uploadNoticeDestructive?.(isError);
        this.uploadNotice.hidden = false;
    }

    /** Hides the upload status notice. */
    private hideUploadNotice(): void {
        if (!this.uploadNotice || !this.uploadNoticeMessage) {
            return;
        }

        this.uploadNoticeMessage.textContent = "";
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

    /** Records a valid Markdown change and notifies autosave and chrome listeners. */
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
     * Carries each page-relative image's short_title (its alt text, else its filename) into the save as
     * indexed form fields, so the server syncs the page's `images.yaml` (RFC-0019, ADR-049). The server
     * reads `image_count` and the `image_path_<i>`/`image_title_<i>` pairs. A no-op when the document has
     * no page-relative images.
     */
    private attachImageMetadata(parameters: Record<string, string>): void {
        const titles = imageShortTitles(this.toMarkdown());
        parameters["image_count"] = String(titles.length);
        titles.forEach((entry, index): void => {
            parameters[`image_path_${index}`] = entry.localPath;
            parameters[`image_title_${index}`] = entry.shortTitle;
        });
    }

    /**
     * Wires the editor's own autosave (RFC-0036, no htmx): every `editor:changed` schedules a debounced
     * `PUT` of the raw document to the save endpoint, and a form submit (the command bar's Save button,
     * or implicit submission from a field) is intercepted into an immediate save. The `<form>` itself
     * stays untouched as the no-JavaScript floor (native POST via the textarea fallback).
     */
    private configureAutosave(): void {
        // No document path, no save target (also keeps detached test editors from scheduling saves).
        if (!this.getAttribute("data-document")) {
            return;
        }

        this.addEventListener("editor:changed", (): void => this.scheduleAutosave());

        const form = this.closest("form");
        if (form instanceof HTMLFormElement) {
            form.addEventListener("submit", (event: Event): void => {
                event.preventDefault();
                void this.performAutosave();
            });
        }
    }

    /** (Re)arms the autosave debounce window after a content change. */
    private scheduleAutosave(): void {
        if (this.autosaveHandle !== null) {
            window.clearTimeout(this.autosaveHandle);
        }

        this.autosaveHandle = window.setTimeout((): void => {
            void this.performAutosave();
        }, autosaveDebounceMilliseconds);
    }

    /**
     * Saves the current document now: a `PUT` of the raw Markdown bytes (frontmatter re-attached, no
     * urlencoding) to the draft resource when versioning is on, else straight to the page. Drives the
     * save-state controller's dirty/saving/settled transitions.
     */
    private async performAutosave(): Promise<void> {
        if (this.autosaveHandle !== null) {
            window.clearTimeout(this.autosaveHandle);
            this.autosaveHandle = null;
        }

        // Track save state against the editor body, which is what the controller's baseline getter returns.
        this.saveController?.markSubmitted(this.toMarkdown());
        this.saveController?.markSaving();

        try {
            const response = await fetch(this.saveEndpoint(), {
                method: "PUT",
                headers: { "Content-Type": "text/markdown; charset=utf-8" },
                body: this.documentMarkdown(),
            });

            if (response.ok) {
                this.saveController?.markSucceeded();
            } else {
                this.saveController?.markFailed(`HTTP ${response.status}`);
            }
        } catch {
            this.saveController?.markFailed("connection error");
        }
    }

    /** The autosave target: the draft resource with versioning on, else the live page. */
    private saveEndpoint(): string {
        const documentPath = this.getAttribute("data-document") ?? "";

        return this.hasAttribute("data-versioning") ? `/drafts/${documentPath}` : `/documents/${documentPath}`;
    }

    /** Renders the save controller's reported view onto the Save button and error text. */
    private applySaveView(view: SaveStateView): void {
        this.setAttribute("data-save-state", view.state);

        if (this.commandBar) {
            this.commandBar.saveLabel = view.buttonLabel;
            this.commandBar.saveDisabled = view.buttonDisabled;
            this.commandBar.flush();
        }

        if (this.saveError && this.saveErrorMessage) {
            this.saveErrorMessage.textContent = view.error ?? "";
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

        this.modeGroup?.sync(this.mode);
        this.widthGroup?.sync(this.effectiveBodyWidth());

        this.setAttribute("data-theme", this.theme);
        this.applyDocumentTheme();
        this.applyVisualTheme();
        this.syncThemeDropdown();

        this.themeGroup?.sync(this.theme);

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
        // Editing the document can rename or remove the section the trigger is naming.
        this.updateSidebarDisclosureLabel();

        if (this.sidebar) {
            this.sidebar.hidden = false;
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

    /** Applies the editor theme selection to the document-level colour scheme class. */
    private applyDocumentTheme(): void {
        const root = document.documentElement;
        const theme = this.resolvedEditorTheme();

        root.classList.toggle("dark", theme === "dark");
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
