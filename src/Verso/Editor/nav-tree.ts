// The navigation tree (RFC-0026): the left-hand panel listing the document tree's sections and pages. The
// server feeds it lazily -- `GET /tree/<path>` returns one folder's immediate children -- and embeds the open
// page's ancestor "spine" (each ancestor folder's children) so the tree opens pre-expanded to the page with no
// load-time fetches (ADR-0059). This module parses that data, builds the panel DOM, expands folders on demand
// (caching fetched children for the session), navigates on click, and creates new pages/sections.

import { hideBlockingOverlay, showBlockingOverlay } from "./blocking-overlay.js";
import {
    type ChromeDropdownElement,
    chromeDropdownEl,
    chromeIconEl,
    chromePanelHeadingEl,
    chromePanelRowEl,
    initBasecoat,
    NETWORK_ERROR,
} from "./chrome.js";
import { themedConfirm } from "./confirm-dialog.js";
import type { MoveOperation, ServerClient, TrashEntry, TreeNodeData } from "./server-client.js";

export type { TreeNodeData } from "./server-client.js";

/** One ancestor folder of the open page and its immediate children, as embedded in `data-tree-spine`. */
export interface SpineEntry {
    path: string;
    children: TreeNodeData[];
}

/** Parse a `[{name,path,kind,hasChildren}]` children array (the `/tree` body); `[]` on absence or malformed input. */
export function parseTreeChildren(json: string | null): TreeNodeData[] {
    return coerceChildren(safeParse(json));
}

/** Parse the server-embedded `data-tree-spine` JSON into ancestor entries; `[]` on absence or malformed input. */
export function parseTreeSpine(json: string | null): SpineEntry[] {
    const parsed = safeParse(json);
    if (!Array.isArray(parsed)) {
        return [];
    }

    const entries: SpineEntry[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const path = (item as Record<string, unknown>)["path"];
            if (typeof path === "string") {
                entries.push({ path, children: coerceChildren((item as Record<string, unknown>)["children"]) });
            }
        }
    }

    return entries;
}

/**
 * The tree node that represents the open document, so the panel can highlight it. A folder's `index.md` is
 * folded into its section (RFC-0026), so an `index.md` page's active node is its section's path; the root
 * `index.md` has no node (`""`); any other page is its own path.
 */
export function activeNodePath(documentPath: string): string {
    if (documentPath === "" || documentPath === "index.md") {
        return "";
    }
    if (documentPath.endsWith("/index.md")) {
        return documentPath.slice(0, -"/index.md".length);
    }
    return documentPath;
}

function safeParse(json: string | null): unknown {
    if (!json) {
        return null;
    }
    try {
        return JSON.parse(json);
    } catch {
        return null;
    }
}

function coerceChildren(parsed: unknown): TreeNodeData[] {
    if (!Array.isArray(parsed)) {
        return [];
    }

    const nodes: TreeNodeData[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const record = item as Record<string, unknown>;
            const name = record["name"];
            const path = record["path"];
            const kind = record["kind"];
            if (typeof name === "string" && typeof path === "string" && (kind === "section" || kind === "page")) {
                nodes.push({ name, path, kind, hasChildren: record["hasChildren"] === true });
            }
        }
    }

    return nodes;
}

const EXPANDED_KEY = "editor-nav-expanded";
const COLLAPSED_KEY = "editor-nav-collapsed";
const CHILDREN_KEY = "editor-nav-children";

/** The parent folder tree path of a node path (`a/b.md` -> `a`, `a/b` -> `a`, top-level -> ``). */
function parentOfPath(path: string): string {
    const index = path.lastIndexOf("/");
    return index < 0 ? "" : path.slice(0, index);
}

/** The index.md document path of a folder (`index.md` at the root), for navigating to a folder. */
function folderIndexPath(folder: string): string {
    return folder === "" ? "index.md" : `${folder}/index.md`;
}

/** Whether two child listings describe the same rendered rows in the same order. */
function sameChildren(left: TreeNodeData[] | undefined, right: TreeNodeData[]): boolean {
    if (!left || left.length !== right.length) {
        return false;
    }
    return left.every((node, index): boolean => {
        const other = right[index];
        return (
            other !== undefined &&
            node.name === other.name &&
            node.path === other.path &&
            node.kind === other.kind &&
            node.hasChildren === other.hasChildren
        );
    });
}

/** How many recent deletions the trash dropdown shows before deferring to the full trash page. */
const TRASH_DROPDOWN_LIMIT = 10;
/** The sentinel menu value that navigates to the full trash page rather than restoring an entry. */
const TRASH_VIEW_ALL = "__view_all__";
/** The full trash page (server-rendered, RFC-0028). */
const TRASH_PAGE_URL = "/trashbin";

/** The undo dropdown's "view all" item value and full-page target (mirrors the trash pair above). */
const UNDO_VIEW_ALL = "__view_all_moves__";

const UNDO_PAGE_URL = "/undo";

/** The server client and UI policy the navigation tree receives from its host. */
export interface NavTreeOptions {
    /** The open document's tree-relative path (`data-document`). */
    documentPath: string;
    /** The embedded ancestor spine, so the open page is pre-expanded without fetches. */
    spine: SpineEntry[];
    /** The named server operations used by the tree. */
    client: ServerClient;
    /** Navigate the browser to a document URL (clicking a node). */
    navigate: (documentPath: string) => void;
    /** Attach a fast hover tooltip showing a node's full label (deep rows truncate). */
    registerTooltip: (target: HTMLElement, text: string) => void;
    /** Surface a transient message in the editor's standard notification area. */
    notify: (message: string, isError: boolean) => void;
}

/**
 * The navigation tree panel. Renders the document tree lazily: only expanded subtrees exist in the DOM, and a
 * folder's children are fetched once and cached for the session (collapse hides the DOM, it does not refetch).
 * The expanded-folder set and collapsed state persist in `localStorage`.
 */
export class NavTreePanel {
    private readonly panel: HTMLElement;
    private readonly list: HTMLUListElement;
    private readonly options: NavTreeOptions;
    private readonly cache = new Map<string, TreeNodeData[]>();
    private readonly spinePaths: Set<string>;
    private readonly expanded: Set<string>;
    /** Folder paths whose last children-fetch failed; rendered as an inline error with a retry. */
    private readonly errors = new Set<string>();
    private readonly activePath: string;
    private collapsed: boolean;
    /** The parent path under which the inline create form is open, or null when no form is shown. */
    private creatingUnder: string | null = null;
    private createTitle = "";
    private createKind: "page" | "section" = "page";
    /** The trash entries backing the trash dropdown (newest first). */
    private trashEntries: TrashEntry[] = [];
    /** A shared in-flight trash listing, so opening the menu cannot duplicate its preload. */
    private trashLoading: Promise<void> | null = null;
    /** The logged moves backing the undo dropdown (most recent first). */
    private moves: MoveOperation[] = [];
    /** A shared in-flight move listing, so opening the menu cannot duplicate its preload. */
    private movesLoading: Promise<void> | null = null;
    /** The undo dropdown (a Basecoat menu anchored to its header button). */
    private readonly undoDropdown: ChromeDropdownElement;
    /** The trash dropdown: recent deletions with quick-restore, plus a link to the full trash page. */
    private readonly trashDropdown: ChromeDropdownElement;
    /** The tree path of the node currently being dragged (for drag-and-drop move), or null. */
    private draggingPath: string | null = null;
    /** A drop zone shown during a drag for moving an item out to the top level (always reachable, unlike the list's empty space). */
    private readonly rootDrop: HTMLDivElement;

    constructor(options: NavTreeOptions) {
        this.options = options;
        this.activePath = activeNodePath(options.documentPath);

        for (const [path, children] of this.loadCachedChildren()) {
            this.cache.set(path, children);
        }
        this.spinePaths = new Set(options.spine.map((entry): string => entry.path));
        for (const entry of options.spine) {
            this.cache.set(entry.path, entry.children);
        }
        this.saveCachedChildren();
        this.expanded = this.loadExpanded(options.spine.map((entry): string => entry.path));
        this.collapsed = this.loadCollapsed();

        this.panel = document.createElement("nav");
        this.panel.className = "markdown-editor__nav";
        this.panel.setAttribute("aria-label", "Document navigation");

        const header = document.createElement("div");
        header.className = "markdown-editor__nav-header";

        // No collapse button here: the editor's toolbar carries the one collapse control, ahead of
        // Edit/Publish, at every width. A second one beside the heading was redundant, and as a
        // narrow-viewport panel it had nothing to collapse to.
        const heading = chromePanelHeadingEl("Pages");

        const collapseAll = document.createElement("button");
        collapseAll.type = "button";
        collapseAll.className = "markdown-editor__nav-collapse-all markdown-editor__nav-op";
        collapseAll.setAttribute("aria-label", "Collapse all");
        collapseAll.setAttribute("data-tooltip", "Collapse all");
        collapseAll.append(chromeIconEl("chevrons-down-up"));
        collapseAll.addEventListener("click", (): void => this.collapseAll());

        this.undoDropdown = this.createUndoDropdown();
        this.trashDropdown = this.createTrashDropdown();
        header.append(heading, collapseAll, this.undoDropdown, this.trashDropdown, this.createRootCreateButton());

        // A top-level drop target. Its space is reserved permanently (so it never reflows the list
        // mid-drag -- a box change during dragstart cancels the native drag); the branded box is only
        // made visible while dragging an item that isn't already at the top level. The root list's
        // empty background is also a target, but it may not exist when the tree fills the panel.
        this.rootDrop = document.createElement("div");
        this.rootDrop.className = "markdown-editor__nav-root-drop";
        this.rootDrop.textContent = "Move to top level";
        this.rootDrop.addEventListener("dragover", (event: DragEvent): void => {
            if (this.canDropInto(this.draggingPath, "")) {
                event.preventDefault();
                this.rootDrop.dataset["dropTarget"] = "true";
            }
        });
        this.rootDrop.addEventListener("dragleave", (): void => {
            delete this.rootDrop.dataset["dropTarget"];
        });
        this.rootDrop.addEventListener("drop", (event: DragEvent): void => {
            event.preventDefault();
            delete this.rootDrop.dataset["dropTarget"];
            void this.dropInto("");
        });

        this.list = document.createElement("ul");
        this.list.className = "markdown-editor__nav-list";
        // The root list's own background is a drop target for moving an item out to the top level
        // (guarded to the list element itself, so a drop on a row is handled by that row, not here).
        this.list.addEventListener("dragover", (event: DragEvent): void => {
            if (event.target === this.list && this.canDropInto(this.draggingPath, "")) {
                event.preventDefault();
                this.list.dataset["dropTarget"] = "true";
            }
        });
        this.list.addEventListener("dragleave", (event: DragEvent): void => {
            if (event.target === this.list) {
                delete this.list.dataset["dropTarget"];
            }
        });
        this.list.addEventListener("drop", (event: DragEvent): void => {
            if (event.target === this.list) {
                event.preventDefault();
                delete this.list.dataset["dropTarget"];
                void this.dropInto("");
            }
        });

        this.panel.append(header, this.rootDrop, this.list);
        this.applyCollapsed();
        this.render();
        // Reveal the open page's row immediately (the rAF inside runs before first paint, so the panel
        // never flashes at the top), then correct after hydrate only if late-loading rows above pushed
        // it back out of view -- an unconditional second reveal would be a visible jump on every load.
        this.revealActive(true);
        // The spine only seeds the open page's ancestors; any other persisted-expanded folder has no cached
        // children yet, so fetch those and re-render -- otherwise it would show expanded (arrow down) but empty.
        void this.hydrate().then((): void => this.revealActive(false));
    }

    /** Checks persisted expanded folders outside the current spine in parallel, then renders changed rows. */
    private async hydrate(): Promise<void> {
        const paths = [...this.expanded].filter((path): boolean => !this.spinePaths.has(path));
        const updates = await Promise.all(
            paths.map(async (path): Promise<{ path: string; children: TreeNodeData[] } | { path: string }> => {
                const result = await this.options.client.loadTreeChildren(path);
                if (!result.ok) {
                    return { path };
                }
                return { path, children: result.value };
            }),
        );
        let changed = false;
        let fetched = false;
        for (const update of updates) {
            if (!("children" in update)) {
                if (!this.cache.has(update.path)) {
                    this.errors.add(update.path);
                    changed = true;
                }
                continue;
            }
            fetched = true;
            this.errors.delete(update.path);
            if (!sameChildren(this.cache.get(update.path), update.children)) {
                this.cache.set(update.path, update.children);
                changed = true;
            }
        }
        if (fetched) {
            this.saveCachedChildren();
        }
        if (changed) {
            this.render();
        }
    }

    element(): HTMLElement {
        return this.panel;
    }

    /** Discards cached children and re-fetches the currently expanded folders (the out-of-band-change escape hatch). */
    async refresh(): Promise<void> {
        this.cache.clear();
        this.errors.clear();
        // Re-fetch the root and every expanded folder concurrently rather than one-by-one: a move on a
        // large tree with many open folders was waiting on a chain of sequential round-trips.
        await Promise.all([this.loadInto(""), ...[...this.expanded].map((path): Promise<void> => this.loadInto(path))]);
        this.render();
    }

    private render(): void {
        this.list.replaceChildren(...this.renderChildren(""));
    }

    /**
     * Scrolls the open page's row into view. Each page load recreates the tree, so without this the
     * panel always starts scrolled to the top and the page just navigated to is often out of sight.
     * Only used while the tree initialises -- later re-renders (expand/collapse, moves) must not yank
     * the scroll position. With `always` false the row is left alone when it is already visible, so
     * the post-hydrate correction only moves the panel when late-loading rows pushed it out of view.
     */
    private revealActive(always: boolean): void {
        if (this.activePath === "") {
            return;
        }
        // After layout: the panel is not attached (or sized) when the constructor renders, and hydrate
        // may have replaced the rows since the call -- so both the lookup and the geometry read run in
        // the callback. rAF fires before the next paint: the initial reveal is never seen as a jump.
        requestAnimationFrame((): void => {
            const row = this.list.querySelector<HTMLElement>('.markdown-editor__nav-row[data-active="true"]');
            if (!row) {
                return;
            }
            const rowTop = row.offsetTop;
            const rowBottom = rowTop + row.offsetHeight;
            const viewTop = this.panel.scrollTop;
            const viewBottom = viewTop + this.panel.clientHeight;
            if (!always && rowTop >= viewTop && rowBottom <= viewBottom) {
                return;
            }
            // Centred (not edge-aligned) so the late layout shifts of a loading page -- fonts and Web
            // Awesome component upgrades resizing rows -- cannot push it straight back out of view.
            this.panel.scrollTop = Math.max(0, rowTop - (this.panel.clientHeight - row.offsetHeight) / 2);
        });
    }

    private renderChildren(parentPath: string): HTMLElement[] {
        const children = this.cache.get(parentPath) ?? [];
        const rows = children.map((node): HTMLElement => this.renderNode(node));
        if (this.creatingUnder === parentPath) {
            rows.unshift(this.renderCreateForm(parentPath));
        }
        return rows;
    }

    private renderNode(node: TreeNodeData): HTMLElement {
        const item = document.createElement("li");
        item.className = "markdown-editor__nav-item";
        item.dataset["kind"] = node.kind;

        // The shared side-panel row (chrome.ts): the tree and the metadata pane draw the same row.
        const { label: rowLabel, root: row } = chromePanelRowEl("div", {
            className: "markdown-editor__nav-row",
            label: node.name,
        });
        if (node.path === this.activePath) {
            row.dataset["active"] = "true";
        }
        row.addEventListener("click", (event: MouseEvent): void => {
            if (event.target === row) {
                this.openNode(node);
            }
        });

        // The label is a button of its own inside the row, so the row actions can sit beside it and the
        // hover fill still covers the whole row; the shared truncating label moves into it.
        const label = document.createElement("button");
        label.type = "button";
        label.className = "markdown-editor__nav-label";
        label.append(rowLabel);
        this.options.registerTooltip(label, node.name); // full label on hover, since deep rows truncate
        label.addEventListener("click", (): void => this.openNode(node));
        row.append(label);

        if (node.kind === "section") {
            row.append(this.createNodeCreateButton(node.path));
        }
        row.append(this.createRowAction("✕", "Delete", node, (): void => void this.deleteNode(node)));

        // The expand/collapse chevron rides the row's trailing edge, as the shadcn sidebar's does. A leaf
        // needs no spacer opposite it: the nesting itself indents the rows, so the labels still line up.
        if (node.kind === "section" && node.hasChildren) {
            row.append(this.createDisclosure(node));
        }

        this.attachDragAndDrop(row, node);

        item.append(row);

        if (node.kind === "section") {
            const sublist = document.createElement("ul");
            sublist.className = "markdown-editor__nav-list";
            item.append(sublist);
            if (this.expanded.has(node.path)) {
                item.dataset["expanded"] = "true";
                if (this.errors.has(node.path)) {
                    sublist.replaceChildren(this.renderError(node.path));
                } else {
                    sublist.replaceChildren(...this.renderChildren(node.path));
                }
            }
        }

        return item;
    }

    /** An inline "couldn't load -- retry" row shown under a section whose children failed to fetch. */
    private renderError(path: string): HTMLElement {
        const item = document.createElement("li");
        item.className = "markdown-editor__nav-error";

        const message = document.createElement("span");
        message.textContent = "Couldn’t load";

        const retry = document.createElement("button");
        retry.type = "button";
        retry.className = "markdown-editor__nav-retry";
        retry.textContent = "Retry";
        retry.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            void this.retry(path);
        });

        item.append(message, retry);
        return item;
    }

    private createDisclosure(node: TreeNodeData): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-disclosure";
        button.setAttribute("aria-label", "Expand or collapse");
        button.append(chromeIconEl("chevron-right")); // CSS rotates the icon when expanded
        button.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            void this.toggleNode(node.path);
        });
        return button;
    }

    private async toggleNode(path: string): Promise<void> {
        if (this.expanded.has(path)) {
            this.expanded.delete(path);
        } else {
            this.expanded.add(path);
            await this.loadInto(path);
        }
        this.saveExpanded();
        this.render();
    }

    /**
     * Opens a node: navigates to it and, for a section with children, expands it too, so clicking a section
     * both shows its landing page and reveals its contents. The expanded set is persisted before navigating,
     * so the section is open when the destination page's tree renders.
     */
    private openNode(node: TreeNodeData): void {
        if (node.kind === "section" && node.hasChildren && !this.expanded.has(node.path)) {
            this.expanded.add(node.path);
            this.saveExpanded();
        }
        this.options.navigate(this.documentUrlFor(node));
    }

    /** Fetches a folder's children into the cache, recording a failure so the node can show an inline error. */
    private async loadInto(path: string): Promise<void> {
        try {
            await this.ensureChildren(path);
            this.errors.delete(path);
        } catch {
            this.errors.add(path);
        }
    }

    /** Fetches a folder's children once (cached for the session). Throws on failure so nothing is cached. */
    private async ensureChildren(path: string): Promise<void> {
        if (this.cache.has(path)) {
            return;
        }
        const result = await this.options.client.loadTreeChildren(path);
        if (!result.ok) {
            throw new Error(result.message);
        }
        this.cache.set(path, result.value);
        this.saveCachedChildren();
    }

    private async retry(path: string): Promise<void> {
        this.errors.delete(path);
        await this.loadInto(path);
        this.render();
    }

    private documentUrlFor(node: TreeNodeData): string {
        return node.kind === "section" ? `${node.path}/index.md` : node.path;
    }

    private createNodeCreateButton(parentPath: string): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-create";
        button.setAttribute("aria-label", "New page or section here");
        button.setAttribute("data-tooltip", "New page or section");
        button.append(chromeIconEl("plus"));
        button.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            this.openCreate(parentPath);
        });
        return button;
    }

    private createRootCreateButton(): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-create";
        button.setAttribute("aria-label", "New top-level page or section");
        button.setAttribute("data-tooltip", "New top-level page or section");
        button.append(chromeIconEl("plus"));
        button.addEventListener("click", (): void => this.openCreate(""));
        return button;
    }

    /** Opens the inline create form under a parent (the root for ""), expanding the parent so it is visible. */
    private openCreate(parentPath: string): void {
        this.creatingUnder = parentPath;
        this.createTitle = "";
        this.createKind = "page";
        if (parentPath !== "" && !this.expanded.has(parentPath)) {
            this.expanded.add(parentPath);
            this.saveExpanded();
            if (!this.cache.has(parentPath)) {
                void this.loadInto(parentPath).then((): void => {
                    this.render();
                    this.focusCreateInput();
                });
            }
        }
        this.render();
        this.focusCreateInput();
    }

    private closeCreate(): void {
        this.creatingUnder = null;
        this.render();
    }

    /** A per-row action button (move/delete) for a node. */
    private createRowAction(glyph: string, label: string, node: TreeNodeData, onClick: () => void): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-action";
        button.setAttribute("aria-label", `${label} ${node.name}`);
        button.setAttribute("data-tooltip", label);
        button.textContent = glyph;
        button.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            onClick();
        });
        return button;
    }

    /**
     * Confirms a move (themed dialog, shown immediately), applies it, and refreshes; surfaces any
     * failure (drives drag-and-drop moves). The confirmation is shown without a server round-trip --
     * the old preview call that computed the changed-file count took seconds on a large folder, so
     * the dialog appears at once and the count is reported afterward, from the applied move's result
     * (the move validates and refuses on its own, so the preview was only ever informational).
     */
    private async runMove(path: string, name: string, destParent: string, slug: string): Promise<void> {
        const into = destParent === "" ? "the top level" : `“${destParent}”`;
        const confirmed = await themedConfirm({
            title: "Move",
            message: `Move “${name}” into ${into}? Links in any affected pages will be updated.`,
            confirmLabel: "Move",
        });
        if (!confirmed) {
            return;
        }
        // The move (server round-trip) and the tree refresh can take seconds on a large tree, and
        // parts of the UI change underneath; block the whole UI with an obvious overlay until done.
        this.options.notify(`Moving “${name}”…`, false);
        await this.withBlockedUI(`Moving “${name}”…`, async (): Promise<boolean> => {
            const applied = await this.options.client.moveTreeNode(path, destParent, slug, true);
            if (!applied.ok) {
                this.options.notify(applied.message, true);
                return false;
            }
            const count = applied.value.changed;
            this.options.notify(`Moved “${name}” — updated links in ${count} file(s).`, false);
            // If the open document moved (the item itself, or a page inside a moved section), follow it
            // to its new location; the navigation reloads the page, so keep the overlay up (return true).
            const openMoved = this.openDocumentUnder(path);
            if (openMoved !== null && applied.value.to) {
                this.options.navigate(applied.value.to + openMoved.slice(path.length));
                return true;
            }
            // Otherwise refresh in place, expanding the destination so the moved item is visible.
            this.expandFolder(destParent);
            await this.refresh();
            return false;
        });
    }

    /**
     * Runs a tree-mutating operation behind a full-UI blocking overlay (the operation is slow and the
     * tree refreshes underneath). The action returns 'true' when it has triggered a navigation -- the
     * overlay is then left up so the page reload clears it, avoiding a flash of unblocked UI; otherwise
     * the overlay is removed when the action settles (including on a thrown error).
     */
    private async withBlockedUI(message: string, action: () => Promise<boolean>): Promise<void> {
        showBlockingOverlay(message);
        let navigating = false;
        try {
            navigating = await action();
        } finally {
            if (!navigating) {
                hideBlockingOverlay();
            }
        }
    }

    /** Marks a folder and its ancestors expanded, so a moved item lands visible rather than hidden inside a collapsed destination. */
    private expandFolder(folder: string): void {
        if (folder === "") {
            return; // the top level is always visible
        }
        let prefix = "";
        for (const segment of folder.split("/")) {
            prefix = prefix === "" ? segment : `${prefix}/${segment}`;
            this.expanded.add(prefix);
        }
        this.saveExpanded();
    }

    /**
     * Makes a node row a drag source and a drop target for move-by-drag. Dropping onto a section drops
     * into it; dropping onto a page drops into that page's folder. The destination and a name are
     * carried on the row so the drop can run the move.
     */
    private attachDragAndDrop(row: HTMLElement, node: TreeNodeData): void {
        const destParent = node.kind === "section" ? node.path : parentOfPath(node.path);
        row.draggable = true;
        row.addEventListener("dragstart", (event: DragEvent): void => {
            this.draggingPath = node.path;
            event.dataTransfer?.setData("text/plain", node.path);
            // Make the (always-space-reserved) top-level drop zone visible, for items not already at
            // the top level. This toggles visibility/colour only -- no box change -- so it is safe to
            // do synchronously in dragstart (a layout change here would cancel the native drag).
            if (this.canDropInto(node.path, "")) {
                this.rootDrop.dataset["active"] = "true";
            }
        });
        row.addEventListener("dragend", (): void => {
            this.draggingPath = null;
            delete this.rootDrop.dataset["active"];
            this.clearDropTargets();
        });
        row.addEventListener("dragover", (event: DragEvent): void => {
            if (this.canDropInto(this.draggingPath, destParent)) {
                event.preventDefault();
                row.dataset["dropTarget"] = "true";
            }
        });
        row.addEventListener("dragleave", (): void => {
            delete row.dataset["dropTarget"];
        });
        row.addEventListener("drop", (event: DragEvent): void => {
            event.preventDefault();
            delete row.dataset["dropTarget"];
            void this.dropInto(destParent);
        });
    }

    /** Whether the dragged node may drop into a destination folder: not its current folder, not itself or its own descendant. */
    private canDropInto(source: string | null, destParent: string): boolean {
        if (source === null) {
            return false;
        }
        if (destParent === parentOfPath(source)) {
            return false; // already there
        }
        return destParent !== source && !destParent.startsWith(`${source}/`); // not into self/descendant
    }

    /** Runs the move for a completed drop (keeping the dragged node's own name). */
    private async dropInto(destParent: string): Promise<void> {
        const source = this.draggingPath;
        this.draggingPath = null;
        if (!this.canDropInto(source, destParent) || source === null) {
            return;
        }
        const name = source.split("/").pop() ?? source;
        await this.runMove(source, name, destParent, "");
    }

    /** Clears any lingering drop-target highlight (after a drag ends). */
    private clearDropTargets(): void {
        for (const el of this.panel.querySelectorAll<HTMLElement>('[data-drop-target="true"]')) {
            delete el.dataset["dropTarget"];
        }
    }

    /** Confirms, then deletes a node (to trash); surfaces the referrer list on a refused delete. */
    private async deleteNode(node: TreeNodeData): Promise<void> {
        const confirmed = await themedConfirm({
            title: "Delete",
            message: `Delete “${node.name}”? It moves to the trash and can be restored.`,
            confirmLabel: "Delete",
            danger: true,
        });
        if (!confirmed) {
            return;
        }
        this.options.notify(`Deleting “${node.name}”…`, false);
        await this.withBlockedUI(`Deleting “${node.name}”…`, async (): Promise<boolean> => {
            const result = await this.options.client.deleteTreeNode(node.path);
            if (!result.ok) {
                this.options.notify(result.message, true);
                return false;
            }
            if (result.value.status === "refused") {
                const pages = result.value.referrers.map((referrer): string => referrer.page).join(", ");
                this.options.notify(`Cannot delete “${node.name}”: still linked from ${pages}.`, true);
                return false;
            }
            this.options.notify(`Deleted “${node.name}” (in trash). Use Undo or Trash to recover.`, false);
            // If the open document was just deleted (the page itself, or anything inside a deleted
            // section), navigate to the parent folder's index rather than leaving the editor on a
            // vanished file (keep the overlay up for the reload); otherwise refresh the tree in place.
            if (this.openDocumentUnder(node.path) !== null) {
                this.options.navigate(folderIndexPath(parentOfPath(node.path)));
                return true;
            }
            await this.refresh();
            return false;
        });
    }

    /**
     * The open document's path if it is at or beneath @oldPath@ (so an operation on @oldPath@ moves
     * the file out from under the editor), else null. A page matches by equality; a section matches
     * its own index.md and any descendant.
     */
    private openDocumentUnder(oldPath: string): string | null {
        const open = this.options.documentPath;
        if (open === oldPath) {
            return open;
        }
        return open.startsWith(`${oldPath}/`) ? open : null;
    }

    /**
     * Builds the undo dropdown: a Basecoat menu whose trigger is the header's undo button and whose
     * items are the logged moves (most recent first), refreshed each time it opens. Choosing an item
     * applies that move's inverse. A floating menu, rather than an inline panel, so it does not push
     * the tree down and reads as a normal dropdown.
     */
    private createUndoDropdown(): ChromeDropdownElement {
        const dropdown = chromeDropdownEl({
            id: "nav-undo-menu",
            className: "markdown-editor__undo-dropdown",
            intent: "icon",
            caret: false,
            triggerLabel: "",
            triggerClassName: "markdown-editor__nav-op",
            ariaLabel: "Undo a move",
            // The nav is a narrow scroll container with a low stacking context; pinned, the menu escapes
            // both (see pinPopover).
            pinned: true,
            items: [{ value: UNDO_VIEW_ALL, label: "View all moves…" }],
            onSelect: (value: string): void => {
                if (value === UNDO_VIEW_ALL) {
                    // The undo page derives its "back" link from the Referer (the page we navigate from).
                    window.location.assign(UNDO_PAGE_URL);
                    return;
                }
                const move = this.moves.find((candidate): boolean => String(candidate.seq) === value);

                if (move) {
                    void this.undoMove(move);
                }
            },
        });
        const trigger = dropdown.querySelector("#nav-undo-menu-trigger");
        trigger?.append(chromeIconEl("undo"));
        trigger?.setAttribute("data-tooltip", "Undo a move");
        // Refresh the logged moves each time the menu is about to open.
        trigger?.addEventListener("click", (): void => void this.loadUndoItems());
        initBasecoat();

        return dropdown;
    }

    /**
     * Loads the logged moves and renders them as menu items (most recent first), or the fetch-failure
     * item, always followed by the link to the full undo page.
     */
    private loadUndoItems(): Promise<void> {
        if (this.movesLoading !== null) {
            return this.movesLoading;
        }

        const loading = this.refreshUndoItems();
        this.movesLoading = loading;
        void loading.then(
            (): void => {
                this.movesLoading = null;
            },
            (): void => {
                this.movesLoading = null;
            },
        );

        return loading;
    }

    private async refreshUndoItems(): Promise<void> {
        const result = await this.options.client.listMoves(10);
        const moves = result.ok ? result.value : null;
        this.moves = [...(moves ?? [])].reverse(); // most recent first
        const moveItems =
            moves === null
                ? [{ value: "", label: NETWORK_ERROR, disabled: true }]
                : this.moves.length === 0
                  ? [{ value: "", label: "No moves to undo", disabled: true }]
                  : this.moves.map((move) => ({ value: String(move.seq), label: `${move.from} → ${move.to}` }));
        this.undoDropdown.setItems([...moveItems, { value: UNDO_VIEW_ALL, label: "View all moves…" }]);
    }

    /** Confirms, then applies the inverse of a chosen move (the item at its destination goes back to its source). */
    private async undoMove(move: MoveOperation): Promise<void> {
        const confirmed = await themedConfirm({
            title: "Undo move",
            message: `Undo this move? “${move.to}” moves back to “${move.from}”.`,
            confirmLabel: "Undo move",
        });
        if (!confirmed) {
            return;
        }
        this.options.notify("Undoing move…", false);
        await this.withBlockedUI("Undoing move…", async (): Promise<boolean> => {
            const result = await this.options.client.undoMove(move.seq);
            this.options.notify(result.ok ? "Undone." : result.message, !result.ok);
            if (!result.ok) {
                return false;
            }
            // The inverse sends the item at `move.to` back to `move.from`; follow the open
            // document if it was there (keep the overlay for the reload), otherwise refresh in place.
            const openUnder = this.openDocumentUnder(move.to);
            if (openUnder !== null) {
                this.options.navigate(move.from + openUnder.slice(move.to.length));
                return true;
            }
            await this.refresh();
            return false;
        });
    }

    /**
     * The trash dropdown: a Basecoat floating menu anchored to a header icon button. It lists the most
     * recent deletions (newest first, capped) for quick one-click restore, and a final item that opens
     * the full trash page for older entries. A dropdown (not the old inline panel) so it does not push
     * the tree down and matches the undo control beside it.
     */
    private createTrashDropdown(): ChromeDropdownElement {
        const dropdown = chromeDropdownEl({
            id: "nav-trash-menu",
            className: "markdown-editor__trash-dropdown",
            intent: "icon",
            caret: false,
            triggerLabel: "",
            triggerClassName: "markdown-editor__nav-op",
            ariaLabel: "Trash",
            // As for the undo menu beside it: pinned, so the nav's overflow cannot clip it.
            pinned: true,
            items: [{ value: TRASH_VIEW_ALL, label: "View all in trash…" }],
            onSelect: (value: string): void => {
                if (value === TRASH_VIEW_ALL) {
                    // The trash page derives its "back" link from the Referer (the page we navigate from).
                    window.location.assign(TRASH_PAGE_URL);
                    return;
                }
                const entry = this.trashEntries.find((candidate): boolean => candidate.id === value);
                if (entry) {
                    void this.restoreEntry(entry);
                }
            },
        });
        const trigger = dropdown.querySelector("#nav-trash-menu-trigger");
        trigger?.append(chromeIconEl("trash"));
        trigger?.setAttribute("data-tooltip", "Trash");
        // Refresh the trash entries each time the menu is about to open.
        trigger?.addEventListener("click", (): void => void this.loadTrashItems());
        initBasecoat();

        return dropdown;
    }

    /**
     * Loads the recent trash entries (newest first, server-ordered) as menu items, capped, plus the
     * "view all" link; a fetch failure renders as the error item instead of a false "empty".
     */
    private loadTrashItems(): Promise<void> {
        if (this.trashLoading !== null) {
            return this.trashLoading;
        }

        const loading = this.refreshTrashItems();
        this.trashLoading = loading;
        void loading.then(
            (): void => {
                this.trashLoading = null;
            },
            (): void => {
                this.trashLoading = null;
            },
        );

        return loading;
    }

    private async refreshTrashItems(): Promise<void> {
        const result = await this.options.client.listTrash(TRASH_DROPDOWN_LIMIT);
        const entries = result.ok ? result.value : null;
        this.trashEntries = entries ?? [];
        const recent = this.trashEntries.slice(0, TRASH_DROPDOWN_LIMIT);
        const entryItems =
            entries === null
                ? [{ value: "", label: NETWORK_ERROR, disabled: true }]
                : recent.length === 0
                  ? [{ value: "", label: "Trash is empty", disabled: true }]
                  : recent.map((entry) => ({ value: entry.id, label: entry.path }));
        this.trashDropdown.setItems([...entryItems, { value: TRASH_VIEW_ALL, label: "View all in trash…" }]);
    }

    /** Confirms, then restores a trashed entry to its origin; opens the restored page (else refreshes the tree). */
    private async restoreEntry(entry: TrashEntry): Promise<void> {
        const confirmed = await themedConfirm({
            title: "Restore",
            message: `Restore “${entry.path}” to its original location?`,
            confirmLabel: "Restore",
        });
        if (!confirmed) {
            return;
        }
        await this.withBlockedUI("Restoring…", async (): Promise<boolean> => {
            const result = await this.options.client.restoreTrashEntry(entry.id);
            this.options.notify(result.ok ? "Restored." : result.message, !result.ok);
            if (!result.ok) {
                return false;
            }
            // Navigate to the restored page (a section has none, so just refresh the tree in place).
            // Returning true keeps the overlay up across the navigation, as the undo flow does.
            if (entry.kind === "page") {
                this.options.navigate(entry.path);
                return true;
            }
            await this.refresh();
            return false;
        });
    }

    private async submitCreate(parentPath: string): Promise<void> {
        const title = this.createTitle.trim();
        if (title === "") {
            this.options.notify("Enter a title for the new page or section.", true);
            this.focusCreateInput();
            return;
        }
        const result = await this.options.client.createTreeNode(parentPath, this.createKind, title);
        if (!result.ok) {
            this.options.notify(
                result.message === NETWORK_ERROR
                    ? "Couldn’t create -- the server is unreachable."
                    : "Couldn’t create -- the server rejected the request.",
                true,
            );
            this.focusCreateInput();
            return;
        }
        this.creatingUnder = null;
        this.options.navigate(`${result.value}?edit`);
    }

    private focusCreateInput(): void {
        this.panel.querySelector<HTMLInputElement>(".markdown-editor__nav-create-input")?.focus();
    }

    /** The inline new-page/new-section form: a title input, a page/section choice, and create/cancel. */
    private renderCreateForm(parentPath: string): HTMLElement {
        const item = document.createElement("li");
        item.className = "markdown-editor__nav-create-form";

        const form = document.createElement("form");
        form.addEventListener("submit", (event: SubmitEvent): void => {
            event.preventDefault();
            void this.submitCreate(parentPath);
        });

        const input = document.createElement("input");
        input.type = "text";
        input.className = "markdown-editor__nav-create-input";
        input.placeholder = "Title";
        input.value = this.createTitle;
        input.addEventListener("input", (): void => {
            this.createTitle = input.value;
        });
        input.addEventListener("keydown", (event: KeyboardEvent): void => {
            if (event.key === "Escape") {
                event.preventDefault();
                this.closeCreate();
            }
        });

        const kinds = document.createElement("div");
        kinds.className = "markdown-editor__nav-create-kind";
        for (const kind of ["page", "section"] as const) {
            const choice = document.createElement("label");
            const radio = document.createElement("input");
            radio.type = "radio";
            radio.name = "nav-create-kind";
            radio.checked = this.createKind === kind;
            radio.addEventListener("change", (): void => {
                this.createKind = kind;
            });
            choice.append(radio, document.createTextNode(kind === "page" ? "Page" : "Section"));
            kinds.append(choice);
        }

        const actions = document.createElement("div");
        actions.className = "markdown-editor__nav-create-actions";
        const create = document.createElement("button");
        create.type = "submit";
        create.textContent = "Create";
        const cancel = document.createElement("button");
        cancel.type = "button";
        cancel.textContent = "Cancel";
        cancel.addEventListener("click", (): void => this.closeCreate());
        actions.append(create, cancel);

        form.append(input, kinds, actions);
        item.append(form);
        return item;
    }

    /**
     * Collapses every folder except the one leading to the open page: the open page's ancestor spine stays
     * expanded, and the open section keeps its own subtree open, so "collapse all" tidies away other branches
     * without hiding where you are.
     */
    private collapseAll(): void {
        this.expanded.clear();
        for (const entry of this.options.spine) {
            this.expanded.add(entry.path);
        }
        if (this.activePath !== "") {
            this.expanded.add(this.activePath);
        }
        this.saveExpanded();
        this.render();
        // Any kept-expanded folder whose children were never cached (e.g. the open section itself) is fetched
        // and re-rendered, so it shows its contents rather than an empty expanded node.
        void this.hydrate();
    }

    /**
     * Shows or hides the rail, persisting the choice. Public because the editor's toolbar carries
     * the collapse control at every width -- the rail's own header button is unreachable once the
     * rail is hidden, and below the rail breakpoint the header is inside the overlay panel.
     */
    public toggleCollapsed(): void {
        this.collapsed = !this.collapsed;
        this.applyCollapsed();
        this.saveCollapsed();
    }

    /** Whether the rail is currently hidden. */
    public isCollapsed(): boolean {
        return this.collapsed;
    }

    private applyCollapsed(): void {
        this.panel.dataset["collapsed"] = this.collapsed ? "true" : "false";
    }

    private loadExpanded(spinePaths: string[]): Set<string> {
        const stored = this.readStorage(EXPANDED_KEY);
        const expanded = new Set<string>(spinePaths);
        if (stored) {
            try {
                const parsed: unknown = JSON.parse(stored);
                if (Array.isArray(parsed)) {
                    for (const value of parsed) {
                        if (typeof value === "string") {
                            expanded.add(value);
                        }
                    }
                }
            } catch {
                // ignore malformed storage
            }
        }
        return expanded;
    }

    /** Reads validated folder children saved by an earlier page in this browser session. */
    private loadCachedChildren(): Map<string, TreeNodeData[]> {
        const cached = new Map<string, TreeNodeData[]>();
        let stored: string | null = null;
        try {
            stored = window.sessionStorage.getItem(CHILDREN_KEY);
        } catch {
            return cached;
        }
        if (!stored) {
            return cached;
        }

        try {
            const parsed: unknown = JSON.parse(stored);
            if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
                return cached;
            }
            for (const [path, value] of Object.entries(parsed)) {
                if (!Array.isArray(value)) {
                    continue;
                }
                const children = parseTreeChildren(JSON.stringify(value));
                if (children.length === value.length) {
                    cached.set(path, children);
                }
            }
        } catch {
            return cached;
        }

        return cached;
    }

    /** Saves the current validated child listings for the next page in this browser session. */
    private saveCachedChildren(): void {
        try {
            window.sessionStorage.setItem(CHILDREN_KEY, JSON.stringify(Object.fromEntries(this.cache)));
        } catch {
            // storage may be unavailable or full; the live fetch path remains authoritative
        }
    }

    private saveExpanded(): void {
        this.writeStorage(EXPANDED_KEY, JSON.stringify([...this.expanded]));
    }

    private loadCollapsed(): boolean {
        return this.readStorage(COLLAPSED_KEY) === "true";
    }

    private saveCollapsed(): void {
        this.writeStorage(COLLAPSED_KEY, this.collapsed ? "true" : "false");
    }

    private readStorage(key: string): string | null {
        try {
            return window.localStorage.getItem(key);
        } catch {
            return null;
        }
    }

    private writeStorage(key: string, value: string): void {
        try {
            window.localStorage.setItem(key, value);
        } catch {
            // storage may be unavailable (private mode); persistence is best-effort
        }
    }
}
