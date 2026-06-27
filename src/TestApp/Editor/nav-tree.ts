// The navigation tree (RFC-0026): the left-hand panel listing the document tree's sections and pages. The
// server feeds it lazily -- `GET /tree/<path>` returns one folder's immediate children -- and embeds the open
// page's ancestor "spine" (each ancestor folder's children) so the tree opens pre-expanded to the page with no
// load-time fetches (ADR-059). This module parses that data, builds the panel DOM, expands folders on demand
// (caching fetched children for the session), navigates on click, and creates new pages/sections.

import { themedConfirm } from "./confirm-dialog.js";
import { elementValue, type WaDropdownSelectEvent } from "./editor-toolbar-shared.js";

/** A navigation-tree node as the server serialises it: a section (folder) or page, with its tree-relative path. */
export interface TreeNodeData {
    name: string;
    path: string;
    kind: "section" | "page";
    hasChildren: boolean;
}

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

/** The parent folder tree path of a node path (`a/b.md` -> `a`, `a/b` -> `a`, top-level -> ``). */
function parentOfPath(path: string): string {
    const index = path.lastIndexOf("/");
    return index < 0 ? "" : path.slice(0, index);
}

/** The index.md document path of a folder (`index.md` at the root), for navigating to a folder. */
function folderIndexPath(folder: string): string {
    return folder === "" ? "index.md" : `${folder}/index.md`;
}

/** A delete outcome from the server: moved to trash, refused with referrers, or an error. */
export interface DeleteResult {
    status: "deleted" | "refused" | "error";
    referrers?: { page: string; link: string }[];
    message?: string;
}

/** A move outcome: applied (or previewed) with the count of files whose links change, the new path, or an error. */
export interface MoveResult {
    ok: boolean;
    changed?: number;
    to?: string;
    message?: string;
}

/** A generic operation outcome (undo/restore/replay) with a human message. */
export interface OpResult {
    ok: boolean;
    message: string;
}

/** A trash entry for the Trash view. */
export interface TrashEntry {
    id: string;
    path: string;
    kind: string;
}

/** A logged move, for the undo picker (most recent first). */
export interface MoveOp {
    seq: number;
    from: string;
    to: string;
}

/** The callbacks the panel needs from the editor element to fetch, create, navigate, and reorganise. */
export interface NavTreeOptions {
    /** The open document's tree-relative path (`data-document`). */
    documentPath: string;
    /** The embedded ancestor spine, so the open page is pre-expanded without fetches. */
    spine: SpineEntry[];
    /** Fetch a folder's immediate children (`GET /tree/<path>`). */
    fetchChildren: (path: string) => Promise<TreeNodeData[]>;
    /** Create a page or section under a parent; resolves to the new page's edit path, or null on failure. */
    createNode: (parentPath: string, kind: "page" | "section", title: string) => Promise<string | null>;
    /** Navigate the browser to a document URL (clicking a node). */
    navigate: (documentPath: string) => void;
    /** Attach a fast hover tooltip showing a node's full label (deep rows truncate). */
    registerTooltip: (target: HTMLElement, text: string) => void;
    /** Surface a transient message in the editor's standard notification area. */
    notify: (message: string, isError: boolean) => void;
    /** Delete a page or section (routes to trash, or refuses with referrers). */
    deleteNode: (path: string) => Promise<DeleteResult>;
    /** Move a page/section: preview (confirm false) returns the impact; apply (confirm true) performs it. */
    moveNode: (path: string, destParent: string, slug: string, confirm: boolean) => Promise<MoveResult>;
    /** Undo a logged operation by its seq (generates and applies its inverse). */
    undo: (seq: number) => Promise<OpResult>;
    /** List the logged moves for the undo picker (most recent first). */
    listMoves: () => Promise<MoveOp[]>;
    /** List the trash entries for the Trash view. */
    listTrash: () => Promise<TrashEntry[]>;
    /** Restore a trash entry to its origin. */
    restore: (id: string) => Promise<OpResult>;
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
    private readonly expanded: Set<string>;
    /** Folder paths whose last children-fetch failed; rendered as an inline error with a retry. */
    private readonly errors = new Set<string>();
    private readonly activePath: string;
    private collapsed: boolean;
    /** The parent path under which the inline create form is open, or null when no form is shown. */
    private creatingUnder: string | null = null;
    private createTitle = "";
    private createKind: "page" | "section" = "page";
    /** Whether the Trash view is open (renders the trash list above the tree). */
    private trashOpen = false;
    private trashEntries: TrashEntry[] = [];
    /** The container the Trash view renders into, between the header and the tree list. */
    private readonly trashPanel: HTMLDivElement;
    /** The logged moves backing the undo dropdown (most recent first), loaded when it opens. */
    private moves: MoveOp[] = [];
    /** The undo dropdown (a `wa-dropdown` anchored to its header button). */
    private readonly undoDropdown: HTMLElement;
    /** The tree path of the node currently being dragged (for drag-and-drop move), or null. */
    private draggingPath: string | null = null;
    /** A drop zone shown during a drag for moving an item out to the top level (always reachable, unlike the list's empty space). */
    private readonly rootDrop: HTMLDivElement;

    constructor(options: NavTreeOptions) {
        this.options = options;
        this.activePath = activeNodePath(options.documentPath);

        for (const entry of options.spine) {
            this.cache.set(entry.path, entry.children);
        }
        this.expanded = this.loadExpanded(options.spine.map((entry): string => entry.path));
        this.collapsed = this.loadCollapsed();

        this.panel = document.createElement("nav");
        this.panel.className = "markdown-editor__nav";
        this.panel.setAttribute("aria-label", "Document navigation");

        const header = document.createElement("div");
        header.className = "markdown-editor__nav-header";

        const toggle = document.createElement("button");
        toggle.type = "button";
        toggle.className = "markdown-editor__nav-toggle";
        toggle.setAttribute("aria-label", "Collapse navigation");
        toggle.textContent = "❮"; // a chevron; CSS rotates it when collapsed
        toggle.addEventListener("click", (): void => this.toggleCollapsed());

        const heading = document.createElement("h2");
        heading.className = "markdown-editor__metadata-heading";
        heading.textContent = "Pages";

        const collapseAll = document.createElement("button");
        collapseAll.type = "button";
        collapseAll.className = "markdown-editor__nav-collapse-all";
        collapseAll.setAttribute("aria-label", "Collapse all");
        collapseAll.title = "Collapse all";
        collapseAll.textContent = "⊟";
        collapseAll.addEventListener("click", (): void => this.collapseAll());

        this.undoDropdown = this.createUndoDropdown();
        const trash = this.createHeaderButton("🗑", "Trash", (): void => void this.toggleTrash());
        header.append(toggle, heading, collapseAll, this.undoDropdown, trash, this.createRootCreateButton());

        this.trashPanel = document.createElement("div");
        this.trashPanel.className = "markdown-editor__nav-trash";
        this.trashPanel.hidden = true;

        // A top-level drop target, revealed only while dragging an item that isn't already at the
        // top level. The root list's empty background is also a target, but it may not exist when the
        // tree fills (or scrolls past) the panel; this zone is always reachable.
        this.rootDrop = document.createElement("div");
        this.rootDrop.className = "markdown-editor__nav-root-drop";
        this.rootDrop.textContent = "Move to top level";
        this.rootDrop.hidden = true;
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

        this.panel.append(header, this.rootDrop, this.trashPanel, this.list);
        this.applyCollapsed();
        this.render();
        // The spine only seeds the open page's ancestors; any other persisted-expanded folder has no cached
        // children yet, so fetch those and re-render -- otherwise it would show expanded (arrow down) but empty.
        void this.hydrate();
    }

    /** Fetches children for persisted-expanded folders not covered by the spine, then re-renders. */
    private async hydrate(): Promise<void> {
        let changed = false;
        for (const path of [...this.expanded]) {
            if (!this.cache.has(path)) {
                await this.loadInto(path);
                changed = true;
            }
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
        await this.loadInto("");
        for (const path of this.expanded) {
            await this.loadInto(path);
        }
        this.render();
    }

    private render(): void {
        this.list.replaceChildren(...this.renderChildren(""));
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

        const row = document.createElement("div");
        row.className = "markdown-editor__nav-row";
        if (node.path === this.activePath) {
            row.dataset["active"] = "true";
        }

        if (node.kind === "section" && node.hasChildren) {
            row.append(this.createDisclosure(node));
        } else {
            const spacer = document.createElement("span");
            spacer.className = "markdown-editor__nav-spacer";
            row.append(spacer);
        }

        const label = document.createElement("button");
        label.type = "button";
        label.className = "markdown-editor__nav-label";
        label.textContent = node.name;
        this.options.registerTooltip(label, node.name); // full label on hover, since deep rows truncate
        label.addEventListener("click", (): void => this.options.navigate(this.documentUrlFor(node)));
        row.append(label);

        if (node.kind === "section") {
            row.append(this.createNodeCreateButton(node.path));
        }
        row.append(this.createRowAction("✕", "Delete", node, (): void => void this.deleteNode(node)));
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
        button.textContent = "▸"; // right-pointing triangle; CSS rotates when expanded
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

    /** Fetches a folder's children into the cache, recording a failure so the node can show an inline error. */
    private async loadInto(path: string): Promise<void> {
        try {
            await this.ensureChildren(path);
            this.errors.delete(path);
        } catch {
            this.errors.add(path);
        }
    }

    /** Fetches a folder's children once (cached for the session). Throws on failure -- nothing is cached. */
    private async ensureChildren(path: string): Promise<void> {
        if (this.cache.has(path)) {
            return;
        }
        this.cache.set(path, await this.options.fetchChildren(path));
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
        button.textContent = "+";
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
        button.textContent = "+";
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

    /** A small header action button (undo/trash/replay). */
    private createHeaderButton(glyph: string, ariaLabel: string, onClick: () => void): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-op";
        button.setAttribute("aria-label", ariaLabel);
        button.title = ariaLabel;
        button.textContent = glyph;
        button.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            onClick();
        });
        return button;
    }

    /** A per-row action button (move/delete) for a node. */
    private createRowAction(glyph: string, label: string, node: TreeNodeData, onClick: () => void): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-action";
        button.setAttribute("aria-label", `${label} ${node.name}`);
        button.title = label;
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
        this.options.notify(`Moving “${name}”…`, false);
        const applied = await this.options.moveNode(path, destParent, slug, true);
        if (!applied.ok) {
            this.options.notify(applied.message ?? "Move failed.", true);
            return;
        }
        const count = applied.changed ?? 0;
        this.options.notify(`Moved “${name}” — updated links in ${count} file(s).`, false);
        // If the open document moved (the item itself, or a page inside a moved section), follow it to
        // its new location instead of leaving the editor on the old path; otherwise refresh in place.
        const openMoved = this.openDocumentUnder(path);
        if (openMoved !== null && applied.to) {
            this.options.navigate(applied.to + openMoved.slice(path.length));
        } else {
            await this.refresh();
        }
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
            // Reveal the top-level drop zone (only for items not already at the top level), but
            // DEFER it: the zone sits above the list, so un-hiding it synchronously here shifts the
            // dragged row's box mid-dragstart, which cancels the native drag in Chrome -- that made
            // nested rows (the only ones that trigger the reveal) appear undraggable. Showing it on a
            // later tick, once the drag is committed, avoids the cancellation.
            if (this.canDropInto(node.path, "")) {
                const dragged = node.path;
                window.setTimeout((): void => {
                    if (this.draggingPath === dragged) {
                        this.rootDrop.hidden = false;
                    }
                }, 0);
            }
        });
        row.addEventListener("dragend", (): void => {
            this.draggingPath = null;
            this.rootDrop.hidden = true;
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
        const result = await this.options.deleteNode(node.path);
        if (result.status === "refused") {
            const pages = (result.referrers ?? []).map((r): string => r.page).join(", ");
            this.options.notify(`Cannot delete “${node.name}”: still linked from ${pages}.`, true);
            return;
        }
        if (result.status === "error") {
            this.options.notify(result.message ?? "Delete failed.", true);
            return;
        }
        this.options.notify(`Deleted “${node.name}” (in trash). Use Undo or Trash to recover.`, false);
        // If the open document was just deleted (the page itself, or anything inside a deleted
        // section), navigate to the parent folder's index rather than leaving the editor on a
        // vanished file; otherwise refresh the tree in place.
        if (this.openDocumentUnder(node.path) !== null) {
            this.options.navigate(folderIndexPath(parentOfPath(node.path)));
        } else {
            await this.refresh();
        }
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
     * Builds the undo dropdown: a `wa-dropdown` whose trigger is the header's undo button and whose
     * items are the logged moves (most recent first), loaded each time it opens. Choosing an item
     * applies that move's inverse. A floating menu, rather than an inline panel, so it does not push
     * the tree down and reads as a normal dropdown.
     */
    private createUndoDropdown(): HTMLElement {
        const dropdown = document.createElement("wa-dropdown");
        dropdown.className = "markdown-editor__undo-dropdown";
        dropdown.setAttribute("placement", "bottom-start");

        // A plain trigger button (not createHeaderButton, whose click handler would stop the event
        // wa-dropdown needs to toggle); styled as a header op button.
        const trigger = document.createElement("button");
        trigger.type = "button";
        trigger.slot = "trigger";
        trigger.className = "markdown-editor__nav-op";
        trigger.setAttribute("aria-label", "Undo a move");
        trigger.title = "Undo a move";
        trigger.textContent = "⤺";
        dropdown.append(trigger);

        dropdown.addEventListener("wa-show", (): void => void this.loadUndoItems());
        dropdown.addEventListener("wa-select", (event: Event): void => {
            const item = (event as WaDropdownSelectEvent).detail.item;
            if (!(item instanceof HTMLElement)) {
                return;
            }
            const move = this.moves.find((candidate): boolean => String(candidate.seq) === elementValue(item));
            if (move) {
                void this.undoMove(move);
            }
        });
        return dropdown;
    }

    /** Loads the logged moves and renders them as dropdown items (keeping the trigger). */
    private async loadUndoItems(): Promise<void> {
        const moves = await this.options.listMoves();
        this.moves = [...moves].reverse(); // most recent first
        const trigger = this.undoDropdown.querySelector('[slot="trigger"]');
        const items =
            this.moves.length === 0
                ? [this.createUndoEmptyItem()]
                : this.moves.map((move): HTMLElement => this.createUndoItem(move));
        this.undoDropdown.replaceChildren(...(trigger ? [trigger] : []), ...items);
    }

    private createUndoItem(move: MoveOp): HTMLElement {
        const item = document.createElement("wa-dropdown-item");
        item.setAttribute("value", String(move.seq));
        item.textContent = `${move.from} → ${move.to}`;
        return item;
    }

    private createUndoEmptyItem(): HTMLElement {
        const item = document.createElement("wa-dropdown-item");
        item.setAttribute("disabled", "");
        item.textContent = "No moves to undo";
        return item;
    }

    /** Applies the inverse of a chosen move (the item at its destination goes back to its source). */
    private async undoMove(move: MoveOp): Promise<void> {
        this.options.notify("Undoing move…", false);
        const result = await this.options.undo(move.seq);
        this.options.notify(result.message, !result.ok);
        if (!result.ok) {
            return;
        }
        // The inverse sends the item at `move.to` back to `move.from`; follow the open
        // document if it was there, otherwise refresh the tree in place.
        const openUnder = this.openDocumentUnder(move.to);
        if (openUnder !== null) {
            this.options.navigate(move.from + openUnder.slice(move.to.length));
        } else {
            await this.refresh();
        }
    }

    /** Opens or closes the Trash view, loading the entries when opening. */
    private async toggleTrash(): Promise<void> {
        this.trashOpen = !this.trashOpen;
        if (this.trashOpen) {
            this.trashEntries = await this.options.listTrash();
        }
        this.renderTrash();
    }

    /** Renders the Trash view (a list of trashed entries each with a Restore button). */
    private renderTrash(): void {
        this.trashPanel.hidden = !this.trashOpen;
        if (!this.trashOpen) {
            this.trashPanel.replaceChildren();
            return;
        }
        const heading = document.createElement("div");
        heading.className = "markdown-editor__nav-trash-heading";
        heading.textContent = this.trashEntries.length === 0 ? "Trash is empty" : "Trash";
        const rows = this.trashEntries.map((entry): HTMLElement => this.renderTrashEntry(entry));
        this.trashPanel.replaceChildren(heading, ...rows);
    }

    private renderTrashEntry(entry: TrashEntry): HTMLElement {
        const row = document.createElement("div");
        row.className = "markdown-editor__nav-trash-row";
        const label = document.createElement("span");
        label.textContent = `${entry.path} (${entry.kind})`;
        const restore = document.createElement("button");
        restore.type = "button";
        restore.className = "markdown-editor__nav-retry";
        restore.textContent = "Restore";
        restore.addEventListener("click", (event: MouseEvent): void => {
            event.stopPropagation();
            void this.restoreEntry(entry);
        });
        row.append(label, restore);
        return row;
    }

    private async restoreEntry(entry: TrashEntry): Promise<void> {
        const result = await this.options.restore(entry.id);
        this.options.notify(result.message, !result.ok);
        if (result.ok) {
            this.trashEntries = await this.options.listTrash();
            this.renderTrash();
            await this.refresh();
        }
    }

    private async submitCreate(parentPath: string): Promise<void> {
        const title = this.createTitle.trim();
        if (title === "") {
            this.options.notify("Enter a title for the new page or section.", true);
            this.focusCreateInput();
            return;
        }
        // The form stays open on failure so the title can be retried; errors go to the standard notice area
        // (a rejected fetch when the server is unreachable throws here, rather than resolving to null).
        try {
            const editPath = await this.options.createNode(parentPath, this.createKind, title);
            if (editPath) {
                this.creatingUnder = null;
                this.options.navigate(`${editPath}?edit`);
            } else {
                this.options.notify("Couldn’t create -- the server rejected the request.", true);
                this.focusCreateInput();
            }
        } catch {
            this.options.notify("Couldn’t create -- the server is unreachable.", true);
            this.focusCreateInput();
        }
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

    private collapseAll(): void {
        this.expanded.clear();
        this.saveExpanded();
        this.render();
    }

    private toggleCollapsed(): void {
        this.collapsed = !this.collapsed;
        this.applyCollapsed();
        this.saveCollapsed();
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
