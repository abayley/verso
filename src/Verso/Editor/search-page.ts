// The search page's instant results: a progressive enhancement of the
// server-rendered form (RFC-0034 follow-up). Typing re-queries the server's
// hybrid search (`/search?json`) with the same debounce and in-flight
// cancellation as the top-bar SearchPanel, and re-renders the result cards in
// place; the URL tracks the query so reload and share keep working. Without
// this script the form still submits as a plain GET.

import { NETWORK_ERROR } from "./chrome.js";
import { editorServerClient, type SearchResult, type ServerClient } from "./server-client.js";

/** Milliseconds of typing quiet before a query is sent (matches SearchPanel). */
const DEBOUNCE_MS = 250;

/** The fewest characters worth querying (matches SearchPanel). */
const MIN_QUERY_LENGTH = 2;

/**
 * Wires the search page's form for instant results via delegated document
 * listeners (the shared bundle is a head script, so the form does not exist
 * yet at install time; same pattern as the trash page). A no-op on other
 * pages, and on a server with search disabled (no output region is rendered).
 * Returns the listeners' remover for tests.
 */
export function installSearchPage(client: Pick<ServerClient, "searchPages"> = editorServerClient): () => void {
    let debounceTimer: number | undefined;
    let inFlight: AbortController | null = null;

    const onInput = (event: Event): void => {
        const input = inputOf(event.target);
        if (input === null || outputRegion() === null) {
            return;
        }
        clearButtonOf(input)?.toggleAttribute("hidden", input.value.length === 0);
        window.clearTimeout(debounceTimer);
        const query = input.value.trim();
        if (query.length < MIN_QUERY_LENGTH) {
            renderNothing();
            syncUrl(query);
            return;
        }
        debounceTimer = window.setTimeout((): void => {
            void search(query);
        }, DEBOUNCE_MS);
    };

    const onSubmit = (event: Event): void => {
        const form = event.target instanceof Element ? event.target.closest(".verso-search-form") : null;
        if (form === null || outputRegion() === null) {
            return;
        }
        // Enter searches now rather than round-tripping through a page load.
        event.preventDefault();
        window.clearTimeout(debounceTimer);
        const query = (form.querySelector("input[name='q']") as HTMLInputElement | null)?.value.trim() ?? "";
        if (query.length >= MIN_QUERY_LENGTH) {
            void search(query);
        }
    };

    const onClick = (event: Event): void => {
        const target = event.target instanceof Element ? event.target : null;
        const clear = target?.closest<HTMLButtonElement>(".verso-search-clear");
        if (clear === null || clear === undefined) {
            return;
        }
        const input = clear.closest(".verso-search-form")?.querySelector<HTMLInputElement>("input[name='q']");
        if (input === undefined || input === null) {
            return;
        }
        window.clearTimeout(debounceTimer);
        input.value = "";
        clear.hidden = true;
        renderNothing();
        syncUrl("");
        input.focus();
    };

    const search = async (query: string): Promise<void> => {
        inFlight?.abort();
        inFlight = new AbortController();
        const result = await client.searchPages(query, inFlight.signal);
        if (!result.ok) {
            if (!result.aborted) {
                renderError();
            }
            return;
        }
        render(result.value.results, result.value.pending);
        syncUrl(query);
    };

    document.addEventListener("input", onInput);
    document.addEventListener("submit", onSubmit);
    document.addEventListener("click", onClick);
    return (): void => {
        window.clearTimeout(debounceTimer);
        document.removeEventListener("input", onInput);
        document.removeEventListener("submit", onSubmit);
        document.removeEventListener("click", onClick);
    };
}

/** The search form's query input, when the event came from it. */
function inputOf(target: EventTarget | null): HTMLInputElement | null {
    if (!(target instanceof HTMLInputElement)) {
        return null;
    }
    return target.closest(".verso-search-form") === null ? null : target;
}

/** The input's sibling clear button. */
function clearButtonOf(input: HTMLInputElement): HTMLButtonElement | null {
    return input.closest(".verso-search-form")?.querySelector<HTMLButtonElement>(".verso-search-clear") ?? null;
}

/** The page's results region (absent when search is disabled or off-page). */
function outputRegion(): HTMLElement | null {
    return document.querySelector<HTMLElement>(".verso-search-output");
}

/** Reflects the query in the URL, so reload and copy-link keep the search. */
function syncUrl(query: string): void {
    const target = query === "" ? "/search" : `/search?q=${encodeURIComponent(query)}`;
    window.history.replaceState(null, "", target);
}

/** Empties the results region (a cleared or too-short query). */
function renderNothing(): void {
    outputRegion()?.replaceChildren();
}

/** Replaces the results region with the unreachable-server notice. */
function renderError(): void {
    const region = outputRegion();
    if (region === null) {
        return;
    }
    const message = document.createElement("p");
    message.className = "verso-search-error";
    message.textContent = NETWORK_ERROR;
    region.replaceChildren(message);
}

/** Renders the pending notice and result cards, mirroring the server's markup. */
function render(results: SearchResult[], pending: number): void {
    const region = outputRegion();
    if (region === null) {
        return;
    }
    region.replaceChildren();
    if (pending > 0) {
        const note = document.createElement("p");
        note.className = "verso-search-pending";
        note.textContent = `Indexing in progress: ${pending} page(s) pending; results may be incomplete.`;
        region.append(note);
    }
    if (results.length === 0) {
        const empty = document.createElement("p");
        empty.textContent = "No results.";
        region.append(empty);
        return;
    }
    const list = document.createElement("ol");
    list.className = "verso-search-results";
    for (const result of results) {
        list.append(resultCard(result));
    }
    region.append(list);
}

/** One result as a Basecoat card (the same shape Verso.View renders). */
function resultCard(result: SearchResult): HTMLLIElement {
    const card = document.createElement("li");
    card.className = "card verso-search-result";

    const header = document.createElement("header");
    const heading = document.createElement("h2");
    heading.className = "verso-search-hit";
    const link = document.createElement("a");
    link.href = `/documents/${result.path.split("/").map(encodeURIComponent).join("/")}`;
    link.textContent = result.path;
    heading.append(link);
    if (result.anchor !== "") {
        const anchor = document.createElement("span");
        anchor.className = "verso-search-anchor";
        anchor.textContent = ` > ${result.anchor}`;
        heading.append(anchor);
    }
    header.append(heading);
    card.append(header);

    const section = document.createElement("section");
    const excerpt = document.createElement("p");
    excerpt.className = "verso-search-excerpt";
    excerpt.textContent = result.excerpt;
    section.append(excerpt);
    card.append(section);
    return card;
}
