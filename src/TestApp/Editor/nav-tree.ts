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
    private readonly expanded: Set<string>;
    /** Folder paths whose last children-fetch failed; rendered as an inline error with a retry. */
    private readonly errors = new Set<string>();
    private readonly activePath: string;
    private collapsed: boolean;
    /** The parent path under which the inline create form is open, or null when no form is shown. */
    private creatingUnder: string | null = null;
    private createTitle = "";
    private createKind: "page" | "section" = "page";

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

        header.append(toggle, heading, collapseAll, this.createRootCreateButton());

        this.list = document.createElement("ul");
        this.list.className = "markdown-editor__nav-list";

        this.panel.append(header, this.list);
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
