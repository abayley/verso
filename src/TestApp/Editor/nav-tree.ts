// The navigation tree (RFC-0026): the left-hand panel listing the document tree's sections and pages. The
// server feeds it lazily -- `GET /tree/<path>` returns one folder's immediate children -- and embeds the open
// page's ancestor "spine" (each ancestor folder's children) so the tree opens pre-expanded to the page with no
// load-time fetches (ADR-059). This module parses that data, builds the panel DOM, expands folders on demand
// (caching fetched children for the session), navigates on click, and creates new pages/sections.

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

/** The callbacks the panel needs from the editor element to fetch, create, and navigate. */
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
    /** Whether the surrounding view is read-only (no create controls). */
    readonly: boolean;
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
    private readonly activePath: string;
    private collapsed: boolean;

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

        header.append(toggle, heading);
        if (!options.readonly) {
            header.append(this.createRootCreateButton());
        }

        this.list = document.createElement("ul");
        this.list.className = "markdown-editor__nav-list";

        this.panel.append(header, this.list);
        this.applyCollapsed();
        this.render();
    }

    element(): HTMLElement {
        return this.panel;
    }

    /** Discards cached children and re-fetches the currently expanded folders (the out-of-band-change escape hatch). */
    async refresh(): Promise<void> {
        this.cache.clear();
        await this.ensureChildren("");
        for (const path of this.expanded) {
            await this.ensureChildren(path);
        }
        this.render();
    }

    private render(): void {
        this.list.replaceChildren(...this.renderChildren(""));
    }

    private renderChildren(parentPath: string): HTMLElement[] {
        const children = this.cache.get(parentPath) ?? [];
        return children.map((node): HTMLElement => this.renderNode(node));
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
        label.addEventListener("click", (): void => this.options.navigate(this.documentUrlFor(node)));
        row.append(label);

        if (node.kind === "section" && !this.options.readonly) {
            row.append(this.createNodeCreateButton(node.path));
        }

        item.append(row);

        if (node.kind === "section") {
            const sublist = document.createElement("ul");
            sublist.className = "markdown-editor__nav-list";
            item.append(sublist);
            if (this.expanded.has(node.path)) {
                item.dataset["expanded"] = "true";
                sublist.replaceChildren(...this.renderChildren(node.path));
            }
        }

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
            await this.ensureChildren(path);
        }
        this.saveExpanded();
        this.render();
    }

    private async ensureChildren(path: string): Promise<void> {
        if (this.cache.has(path)) {
            return;
        }
        try {
            this.cache.set(path, await this.options.fetchChildren(path));
        } catch {
            this.cache.set(path, []);
        }
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
            void this.promptCreate(parentPath);
        });
        return button;
    }

    private createRootCreateButton(): HTMLButtonElement {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "markdown-editor__nav-create";
        button.setAttribute("aria-label", "New top-level page or section");
        button.textContent = "+";
        button.addEventListener("click", (): void => void this.promptCreate(""));
        return button;
    }

    private async promptCreate(parentPath: string): Promise<void> {
        const title = window.prompt("Title for the new page or section:");
        if (!title || title.trim() === "") {
            return;
        }
        const section = window.confirm("Create a section (folder)? Cancel for a single page.");
        const editPath = await this.options.createNode(parentPath, section ? "section" : "page", title.trim());
        if (editPath) {
            // Reveal the parent so the new node is visible after the (lazy) re-read, then open it for editing.
            this.expanded.add(parentPath);
            this.saveExpanded();
            this.cache.delete(parentPath);
            this.options.navigate(`${editPath}?edit`);
        }
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
