import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import { installSearchPage } from "../src/search-page.js";
import type { SearchResponse, SearchResult, ServerClient, ServerResult } from "../src/server-client.js";

const searchResult = (results: SearchResult[], pending = 0): ServerResult<SearchResponse> => ({
    ok: true,
    value: { enabled: true, pending, results },
});

/** A recording fake for the search page's server seam. */
interface SearchClientFake {
    searchPages: Mock<ServerClient["searchPages"]>;
}

/** Creates a recording fake for the search page's server seam. */
const fakeClient = (result: ServerResult<SearchResponse>): SearchClientFake => {
    const searchPages = vi.fn<ServerClient["searchPages"]>();
    searchPages.mockResolvedValue(result);
    return { searchPages };
};

const aResult = {
    path: "guides/failover.md",
    title: "Failover Guide",
    anchor: "Timeouts",
    excerpt: "Configure the SmartWAN failover timeouts.",
};

/** The server-rendered search page's enhanced parts (form, clear button, output region). */
const mountSearchPage = (): void => {
    document.body.innerHTML = `
        <form class="verso-search-form" method="get" action="/search">
            <div class="verso-search-box">
                <input class="input" type="search" name="q" value="">
                <button type="button" class="verso-search-clear" hidden></button>
            </div>
        </form>
        <div class="verso-search-output"></div>`;
};

const queryInput = (): HTMLInputElement => document.querySelector(".verso-search-form input") as HTMLInputElement;
const output = (): HTMLElement => document.querySelector(".verso-search-output") as HTMLElement;
const clearButton = (): HTMLButtonElement => document.querySelector(".verso-search-clear") as HTMLButtonElement;

const type = (value: string): void => {
    queryInput().value = value;
    queryInput().dispatchEvent(new Event("input", { bubbles: true }));
};

describe("installSearchPage", (): void => {
    let uninstall: (() => void) | null = null;

    beforeEach((): void => {
        vi.useFakeTimers();
        mountSearchPage();
    });

    afterEach((): void => {
        uninstall?.();
        uninstall = null;
        vi.restoreAllMocks();
        vi.useRealTimers();
        document.body.innerHTML = "";
    });

    it("given several keystrokes in quick succession, when the debounce elapses, then one query runs and its result cards render", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult]));
        uninstall = installSearchPage(client);

        for (const value of ["f", "fa", "fai", "failover"]) {
            type(value);
        }
        await vi.advanceTimersByTimeAsync(300);

        expect(client.searchPages).toHaveBeenCalledTimes(1);
        expect(client.searchPages).toHaveBeenCalledWith("failover", expect.any(AbortSignal));
        const card = output().querySelector("li.card.verso-search-result") as HTMLElement;
        expect(card).not.toBeNull();
        const link = card.querySelector(".verso-search-hit a") as HTMLAnchorElement;
        expect(link.getAttribute("href")).toBe("/documents/guides/failover.md");
        expect(link.textContent).toBe("guides/failover.md");
        expect(card.querySelector(".verso-search-anchor")?.textContent).toContain("Timeouts");
        expect(card.querySelector(".verso-search-excerpt")?.textContent).toContain("SmartWAN");
    });

    it("given a query below the minimum length, when it is typed, then no query runs and stale output is cleared", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult]));
        uninstall = installSearchPage(client);
        output().innerHTML = "<p>stale</p>";

        type("f");
        await vi.advanceTimersByTimeAsync(300);

        expect(client.searchPages).not.toHaveBeenCalled();
        expect(output().textContent).toBe("");
    });

    it("given text in the field, when the clear button is clicked, then the field and the results are cleared", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult]));
        uninstall = installSearchPage(client);

        type("failover");
        expect(clearButton().hidden).toBe(false);
        await vi.advanceTimersByTimeAsync(300);
        expect(output().querySelector(".verso-search-result")).not.toBeNull();

        clearButton().dispatchEvent(new MouseEvent("click", { bubbles: true }));
        expect(queryInput().value).toBe("");
        expect(clearButton().hidden).toBe(true);
        expect(output().textContent).toBe("");
    });

    it("given a query that fails, when it returns, then the unreachable-server notice is rendered", async (): Promise<void> => {
        const client = fakeClient({ ok: false, message: "Couldn’t reach the server." });
        uninstall = installSearchPage(client);

        type("failover");
        await vi.advanceTimersByTimeAsync(300);

        expect(output().querySelector(".verso-search-error")?.textContent).toContain("Couldn’t reach the server");
    });

    it("given results with indexing still pending, when they render, then the pending notice appears ahead of them", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult], 3));
        uninstall = installSearchPage(client);

        type("failover");
        await vi.advanceTimersByTimeAsync(300);

        expect(output().querySelector(".verso-search-pending")?.textContent).toContain("3 page(s) pending");
        expect(output().querySelector(".verso-search-result")).not.toBeNull();
    });

    it("given the form is submitted, when the event fires, then the submit is prevented and the search runs immediately", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult]));
        uninstall = installSearchPage(client);

        queryInput().value = "failover";
        const submit = new Event("submit", { bubbles: true, cancelable: true });
        document.querySelector(".verso-search-form")?.dispatchEvent(submit);
        await vi.advanceTimersByTimeAsync(0);

        expect(submit.defaultPrevented).toBe(true);
        expect(client.searchPages).toHaveBeenCalledTimes(1);
    });

    it("given a query, when it runs, then the page URL follows it", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult]));
        uninstall = installSearchPage(client);

        type("failover");
        await vi.advanceTimersByTimeAsync(300);
        expect(window.location.search).toBe("?q=failover");
    });

    it("given the page has been uninstalled, when typing continues, then nothing responds", async (): Promise<void> => {
        const client = fakeClient(searchResult([aResult]));
        uninstall = installSearchPage(client);
        uninstall();
        uninstall = null;

        type("failover");
        await vi.advanceTimersByTimeAsync(300);
        expect(client.searchPages).not.toHaveBeenCalled();
    });
});
