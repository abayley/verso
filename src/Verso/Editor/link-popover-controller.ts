import type { CodeMirrorSourceSelection } from "./codemirror-source-editor.js";
import { LinkActionsElement, LinkEditorElement } from "./link-popover-elements.js";
import type { VisualLinkSelection } from "./tiptap-visual-editor.js";
import type { ToolbarTooltipController } from "./toolbar-tooltip-controller.js";

/** The grace period before existing-link hover actions hide. */
const linkActionsHideDelayMilliseconds = 500;

/**
 * What the link popover controller needs from its host (RFC-0002): the shared tooltip (so the popover's
 * Lit views can register their controls), overlay positioning (shared with the bubble/slash surfaces, so
 * it stays in the element), and the editor-adapter routing for capturing selections and applying or
 * removing links. Inputs are explicit constructor dependencies.
 */
export interface LinkPopoverHost {
    tooltipController: ToolbarTooltipController | null;
    position(overlay: HTMLElement, anchor: DOMRect): void;
    editorAnchorRect(anchorRect: DOMRect | null): DOMRect;
    usingSource(): boolean;
    captureSourceSelection(): CodeMirrorSourceSelection | null;
    applyLink(
        href: string,
        sourceSelection: CodeMirrorSourceSelection | null,
        visualSelection: VisualLinkSelection | null,
    ): void;
    removeLink(selection: VisualLinkSelection): void;
    editorPresent(): boolean;
    visualAnchorAt(target: Element): HTMLAnchorElement | null;
    linkSelectionFromAnchor(anchor: HTMLAnchorElement): VisualLinkSelection | null;
}

/**
 * The editor's link popover (RFC-0002), extracted from the custom element as a
 * plain controller. It owns the link target editor, the existing-link hover
 * actions, the hide grace timer, the pending source/visual selection captured
 * when the popover opens, and the document pointer dismissal/hover wiring. The
 * two Lit view elements render the controls and emit events; this controller
 * keeps all state and the host supplies positioning and editor-adapter operations.
 */
export class LinkPopoverController {
    private readonly host: LinkPopoverHost;
    private readonly editor: LinkEditorElement;
    private readonly actions: LinkActionsElement;
    private pendingLink = false;
    private pendingSourceSelection: CodeMirrorSourceSelection | null = null;
    private pendingVisualSelection: VisualLinkSelection | null = null;
    private activeSelection: VisualLinkSelection | null = null;
    private activeRect: DOMRect | null = null;
    private hideTimeout: number | null = null;

    constructor(host: LinkPopoverHost) {
        this.host = host;
        this.editor = new LinkEditorElement();
        this.editor.className = "markdown-editor__link-editor";
        this.editor.hidden = true;
        this.editor.tooltipController = host.tooltipController;
        this.editor.addEventListener("link-apply", (): void => this.applyTarget());
        this.editor.addEventListener("link-cancel", (): void => this.hideEditor());

        this.actions = new LinkActionsElement();
        this.actions.className = "markdown-editor__link-actions";
        this.actions.hidden = true;
        this.actions.tooltipController = host.tooltipController;
        this.actions.addEventListener("link-edit", (): void => this.editActive());
        this.actions.addEventListener("link-remove", (): void => this.removeActive());
        this.actions.addEventListener("pointerover", (): void => this.cancelHide());
    }

    /** The link target editor element, appended once by the host. */
    public editorElement(): HTMLElement {
        return this.editor;
    }

    /** The existing-link hover actions element, appended once by the host. */
    public actionsElement(): HTMLElement {
        return this.actions;
    }

    /** Opens the link target editor, capturing the pane's current selection. */
    public openEditor(
        href = "",
        visualSelection: VisualLinkSelection | null = null,
        anchorRect: DOMRect | null = null,
    ): void {
        this.hideActions();
        this.pendingLink = true;
        this.pendingSourceSelection = this.host.usingSource() ? this.host.captureSourceSelection() : null;
        this.pendingVisualSelection = visualSelection;
        this.editor.value = href;
        this.editor.hidden = false;
        this.host.position(this.editor, this.host.editorAnchorRect(anchorRect));
        this.editor.focusInput();
        window.setTimeout((): void => {
            if (this.pendingLink) {
                document.addEventListener("pointerdown", this.handleDocumentPointerDown);
            }
        }, 0);
    }

    /** Clears timers and document listeners when the element disconnects. */
    public dispose(): void {
        this.cancelHide();
        document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
        document.removeEventListener("pointerover", this.handleDocumentPointerOver);
    }

    /** Shows hover actions for a rendered link the pointer entered (visual pane). */
    public readonly handleVisualPointerOver = (event: PointerEvent): void => {
        const target = event.target;

        if (!(target instanceof Element) || !this.host.editorPresent()) {
            return;
        }

        const anchor = this.host.visualAnchorAt(target);

        if (!anchor) {
            this.scheduleHide();
            return;
        }

        const selection = this.host.linkSelectionFromAnchor(anchor);

        if (!selection) {
            this.hideActions();
            return;
        }

        this.showActions(selection, anchor.getBoundingClientRect());
    };

    private readonly handleDocumentPointerDown = (event: PointerEvent): void => {
        if (!this.pendingLink && !this.isActionsVisible()) {
            return;
        }

        const target = event.target;

        if (target instanceof Node && this.editor.contains(target)) {
            return;
        }

        if (target instanceof Node && this.actions.contains(target)) {
            return;
        }

        if (this.pendingLink) {
            this.hideEditor();
        }

        if (this.isActionsVisible()) {
            this.hideActions();
        }
    };

    private readonly handleDocumentPointerOver = (event: PointerEvent): void => {
        const target = event.target;

        if (!(target instanceof Element) || !this.host.editorPresent()) {
            this.scheduleHide();
            return;
        }

        if (this.actions.contains(target)) {
            this.cancelHide();
            return;
        }

        if (this.host.visualAnchorAt(target)) {
            this.cancelHide();
            return;
        }

        this.scheduleHide();
    };

    private hideEditor(): void {
        this.pendingLink = false;
        this.pendingSourceSelection = null;
        this.pendingVisualSelection = null;
        this.editor.value = "";
        this.editor.hidden = true;

        if (!this.isActionsVisible()) {
            document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
        }
    }

    private applyTarget(): void {
        if (!this.pendingLink) {
            return;
        }

        const href = this.editor.value.trim();

        if (!href) {
            return;
        }

        const sourceSelection = this.pendingSourceSelection;
        const visualSelection = this.pendingVisualSelection;
        this.hideEditor();
        this.host.applyLink(href, sourceSelection, visualSelection);
    }

    private showActions(selection: VisualLinkSelection, anchorRect: DOMRect): void {
        if (this.pendingLink) {
            return;
        }

        this.activeRect = anchorRect;
        this.activeSelection = selection;
        this.cancelHide();
        this.actions.hidden = false;
        this.host.position(this.actions, anchorRect);
        document.addEventListener("pointerdown", this.handleDocumentPointerDown);
        document.addEventListener("pointerover", this.handleDocumentPointerOver);
    }

    private hideActions(): void {
        this.activeSelection = null;
        this.activeRect = null;
        this.cancelHide();
        this.actions.hidden = true;
        document.removeEventListener("pointerover", this.handleDocumentPointerOver);

        if (!this.pendingLink) {
            document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
        }
    }

    private scheduleHide(): void {
        if (!this.isActionsVisible() || this.hideTimeout !== null) {
            return;
        }

        this.hideTimeout = window.setTimeout((): void => {
            this.hideTimeout = null;
            this.hideActions();
        }, linkActionsHideDelayMilliseconds);
    }

    private cancelHide(): void {
        if (this.hideTimeout === null) {
            return;
        }

        window.clearTimeout(this.hideTimeout);
        this.hideTimeout = null;
    }

    private isActionsVisible(): boolean {
        return !this.actions.hidden;
    }

    private editActive(): void {
        const selection = this.activeSelection;

        if (!selection) {
            return;
        }

        this.openEditor(selection.href, selection, this.activeRect);
    }

    private removeActive(): void {
        const selection = this.activeSelection;

        if (!selection) {
            return;
        }

        this.hideActions();
        this.host.removeLink(selection);
    }
}
