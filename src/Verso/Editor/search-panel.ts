// The interactive search box in the editor's top bar (RFC-0034).
// As the user types, it queries the server's hybrid search (`/search?json`)
// with a short debounce and in-flight cancellation, and renders the top
// results as title-plus-excerpt rows; clicking (or Enter on) a row navigates
// to that page. The panel probes search availability once on mount and hides
// itself entirely when the server has search disabled.

/** One search result row, as the server's json flavour reports it. */
interface SearchResult {
    path: string;
    title: string;
    anchor: string;
    excerpt: string;
}

/** The server's `/search?json` response shape. */
interface SearchResponse {
    enabled: boolean;
    pending?: number;
    results?: SearchResult[];
}

/** Milliseconds of typing quiet before a query is sent. */
const DEBOUNCE_MS = 250;

/** The fewest characters worth querying. */
const MIN_QUERY_LENGTH = 2;

/**
 * The search panel: a search input whose dropdown of results refines as the
 * user types. Keyboard: arrows move the selection, Enter opens it, Escape
 * closes the dropdown; Cmd/Ctrl+K focuses the box from anywhere.
 */
export class SearchPanel {
    private readonly panel: HTMLElement;
    private readonly input: HTMLInputElement;
    private readonly dropdown: HTMLElement;
    private readonly backdrop: HTMLElement;
    private debounceTimer: number | undefined;
    private inFlight: AbortController | null = null;
    private results: SearchResult[] = [];
    private selected = -1;

    constructor(private readonly navigate: (path: string) => void = SearchPanel.defaultNavigate) {
        this.panel = document.createElement("div");
        this.panel.className = "markdown-editor__search";
        this.panel.hidden = true;

        this.input = document.createElement("input");
        this.input.type = "search";
        this.input.className = "markdown-editor__search-input";
        this.input.placeholder = "Search pages…";
        this.input.setAttribute("aria-label", "Search pages");

        this.dropdown = document.createElement("div");
        this.dropdown.className = "markdown-editor__search-results";
        this.dropdown.hidden = true;

        // A transparent click-catcher behind the open dropdown: a click on the
        // softened page lands here (outside the panel), so the document click
        // handler closes the dropdown instead of the click acting on the page.
        // The visual softening itself is CSS keyed on the editor element's
        // data-search-open attribute (set while the dropdown is open), which
        // blurs the workspace in every theme regardless of stacking order.
        this.backdrop = document.createElement("div");
        this.backdrop.className = "markdown-editor__search-backdrop";
        this.backdrop.hidden = true;
        document.body.append(this.backdrop);

        this.input.addEventListener("input", (): void => this.onInput());
        this.input.addEventListener("keydown", (event: KeyboardEvent): void => this.onKey(event));
        this.panel.append(this.input, this.dropdown);

        document.addEventListener("keydown", (event: KeyboardEvent): void => {
            if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
                event.preventDefault();
                this.input.focus();
                this.input.select();
            }
        });
        document.addEventListener("click", (event: MouseEvent): void => {
            if (!this.panel.contains(event.target as Node)) {
                this.close();
            }
        });
    }

    /** The panel element, for placement in the editor's top bar. */
    public element(): HTMLElement {
        return this.panel;
    }

    /** Probes search availability; the panel stays hidden when disabled. */
    public async connect(): Promise<void> {
        try {
            const response = await fetch("/search?json&q=");
            const body = (await response.json()) as SearchResponse;
            this.panel.hidden = !body.enabled;
        } catch {
            this.panel.hidden = true;
        }
    }

    private onInput(): void {
        window.clearTimeout(this.debounceTimer);
        const query = this.input.value.trim();
        if (query.length < MIN_QUERY_LENGTH) {
            this.close();
            return;
        }
        this.debounceTimer = window.setTimeout((): void => {
            void this.search(query);
        }, DEBOUNCE_MS);
    }

    private async search(query: string): Promise<void> {
        this.inFlight?.abort();
        this.inFlight = new AbortController();
        try {
            const response = await fetch(`/search?json&q=${encodeURIComponent(query)}`, {
                signal: this.inFlight.signal,
            });
            // Every result the server sends (it caps at one-per-page anyway);
            // the dropdown scrolls rather than truncating.
            const body = (await response.json()) as SearchResponse;
            this.results = body.results ?? [];
            this.selected = -1;
            this.render(query, body.pending ?? 0);
        } catch (error) {
            if ((error as Error).name !== "AbortError") {
                this.close();
            }
        }
    }

    private render(query: string, pending: number): void {
        this.dropdown.replaceChildren();
        this.dropdown.hidden = false;
        this.backdrop.hidden = false;
        this.panel.closest("markdown-editor")?.setAttribute("data-search-open", "");

        if (pending > 0) {
            const note = document.createElement("p");
            note.className = "markdown-editor__search-pending";
            note.textContent = `Indexing: ${pending} page(s) pending`;
            this.dropdown.append(note);
        }
        if (this.results.length === 0) {
            const empty = document.createElement("p");
            empty.className = "markdown-editor__search-empty";
            empty.textContent = "No results";
            this.dropdown.append(empty);
            return;
        }
        this.results.forEach((result: SearchResult, index: number): void => {
            // A real link, so the browser's native modified-click behaviours work
            // (Cmd/Ctrl-click opens a new tab, middle-click, copy link address).
            const row = document.createElement("a");
            row.className = "markdown-editor__search-row";
            row.href = SearchPanel.pageHref(result.path);
            row.dataset["index"] = String(index);

            const title = document.createElement("span");
            title.className = "markdown-editor__search-title";
            title.textContent = result.title;
            row.append(title);

            if (result.anchor !== "" && result.anchor !== result.title) {
                const anchor = document.createElement("span");
                anchor.className = "markdown-editor__search-anchor";
                anchor.textContent = ` › ${result.anchor}`;
                row.append(anchor);
            }

            // The page's folder path, so same-titled pages can be told apart.
            const folders = result.path.split("/").slice(0, -1);
            if (folders.length > 0) {
                const crumb = document.createElement("span");
                crumb.className = "markdown-editor__search-crumb";
                crumb.textContent = folders.join(" / ");
                row.append(crumb);
            }

            const excerpt = document.createElement("span");
            excerpt.className = "markdown-editor__search-excerpt";
            excerpt.textContent = result.excerpt;
            row.append(excerpt);

            row.addEventListener("click", (event: MouseEvent): void => {
                // A modified click is the browser's business (new tab/window);
                // a plain click navigates through the panel's callback.
                if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
                    return;
                }
                event.preventDefault();
                this.navigate(result.path);
            });
            this.dropdown.append(row);
        });

        const all = document.createElement("a");
        all.className = "markdown-editor__search-all";
        all.href = `/search?q=${encodeURIComponent(query)}`;
        all.textContent = "See all results";
        this.dropdown.append(all);
    }

    private onKey(event: KeyboardEvent): void {
        if (this.dropdown.hidden) {
            return;
        }
        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            const step = event.key === "ArrowDown" ? 1 : -1;
            const count = this.results.length;
            if (count > 0) {
                this.selected = (this.selected + step + count) % count;
                this.highlight();
            }
        } else if (event.key === "Enter" && this.selected >= 0) {
            event.preventDefault();
            const chosen = this.results[this.selected];
            if (chosen) {
                this.navigate(chosen.path);
            }
        } else if (event.key === "Escape") {
            this.close();
        }
    }

    private highlight(): void {
        const rows = this.dropdown.querySelectorAll<HTMLElement>(".markdown-editor__search-row");
        rows.forEach((row: HTMLElement, index: number): void => {
            row.dataset["selected"] = index === this.selected ? "true" : "false";
        });
    }

    private close(): void {
        this.dropdown.hidden = true;
        this.backdrop.hidden = true;
        this.panel.closest("markdown-editor")?.removeAttribute("data-search-open");
        this.dropdown.replaceChildren();
        this.results = [];
        this.selected = -1;
    }

    private static defaultNavigate(path: string): void {
        window.location.href = SearchPanel.pageHref(path);
    }

    /** The page's URL, with each tree-path segment encoded. */
    private static pageHref(path: string): string {
        return `/documents/${path.split("/").map(encodeURIComponent).join("/")}`;
    }
}
