import type { CodeMirrorSourceSelection } from "./codemirror-source-editor.js";
import type { VisualLinkSelection } from "./tiptap-visual-editor.js";

/** The grace period before existing-link hover actions hide. */
const linkActionsHideDelayMilliseconds = 500;

/**
 * What the link popover controller needs from its host (RFC-0002): DOM control
 * factories, overlay positioning (shared with the bubble/slash surfaces, so it
 * stays in the element), and the editor-adapter routing for capturing selections
 * and applying or removing links. Inputs are explicit constructor dependencies.
 */
export interface LinkPopoverHost {
    createButton(className: string, label: string): HTMLElement;
    createIcon(name: string, label: string): HTMLElement;
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
 * element supplies positioning and the editor-adapter operations through the host.
 */
export class LinkPopoverController {
    private readonly host: LinkPopoverHost;
    private readonly editor: HTMLDivElement;
    private readonly input: HTMLInputElement;
    private readonly actions: HTMLDivElement;
    private pendingLink = false;
    private pendingSourceSelection: CodeMirrorSourceSelection | null = null;
    private pendingVisualSelection: VisualLinkSelection | null = null;
    private activeSelection: VisualLinkSelection | null = null;
    private activeRect: DOMRect | null = null;
    private hideTimeout: number | null = null;

    constructor(host: LinkPopoverHost) {
        this.host = host;
        this.editor = this.createEditor();
        this.input = this.editor.querySelector("input") as HTMLInputElement;
        this.actions = this.createActions();
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
        this.input.value = href;
        this.editor.hidden = false;
        this.host.position(this.editor, this.host.editorAnchorRect(anchorRect));
        this.input.focus();
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

    private createEditor(): HTMLDivElement {
        const editor = document.createElement("div");
        editor.className = "markdown-editor__link-editor";
        editor.hidden = true;

        const input = document.createElement("input");
        input.className = "markdown-editor__link-target";
        input.placeholder = "Link target";
        input.type = "url";

        const applyButton = this.host.createButton("markdown-editor__link-apply", "Apply");
        applyButton.addEventListener("click", (): void => this.applyTarget());

        const cancelButton = this.host.createButton("markdown-editor__link-cancel", "Cancel");
        cancelButton.addEventListener("click", (): void => this.hideEditor());

        input.addEventListener("keydown", (event: KeyboardEvent): void => {
            if (event.key === "Enter") {
                event.preventDefault();
                this.applyTarget();
            }

            if (event.key === "Escape") {
                event.preventDefault();
                this.hideEditor();
            }
        });

        editor.append(input, applyButton, cancelButton);

        return editor;
    }

    private createActions(): HTMLDivElement {
        const actions = document.createElement("div");
        actions.className = "markdown-editor__link-actions";
        actions.hidden = true;

        const editButton = this.host.createButton("markdown-editor__link-edit", "Edit link");
        editButton.textContent = "";
        editButton.append(this.host.createIcon("pencil", "Edit link"));
        editButton.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        editButton.addEventListener("click", (): void => this.editActive());

        const removeButton = this.host.createButton("markdown-editor__link-remove", "Remove link");
        removeButton.textContent = "";
        removeButton.append(this.host.createIcon("link-slash", "Remove link"));
        removeButton.addEventListener("mousedown", (event: MouseEvent): void => {
            event.preventDefault();
        });
        removeButton.addEventListener("click", (): void => this.removeActive());
        actions.addEventListener("pointerover", (): void => this.cancelHide());

        actions.append(editButton, removeButton);

        return actions;
    }

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
        this.input.value = "";
        this.editor.hidden = true;

        if (!this.isActionsVisible()) {
            document.removeEventListener("pointerdown", this.handleDocumentPointerDown);
        }
    }

    private applyTarget(): void {
        if (!this.pendingLink) {
            return;
        }

        const href = this.input.value.trim();

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
