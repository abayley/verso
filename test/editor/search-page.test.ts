import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installSearchPage } from "../../src/Verso/Editor/search-page.js";

const searchResponse = (results: object[], pending = 0): Response =>
    new Response(JSON.stringify({ enabled: true, pending, results }), {
        headers: { "Content-Type": "application/json" },
    });

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

    it("debounces typing into one query and renders result cards", async (): Promise<void> => {
        const fetchMock = vi.fn().mockResolvedValue(searchResponse([aResult]));
        vi.stubGlobal("fetch", fetchMock);
        uninstall = installSearchPage();

        for (const value of ["f", "fa", "fai", "failover"]) {
            type(value);
        }
        await vi.advanceTimersByTimeAsync(300);

        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(fetchMock.mock.calls[0]?.[0]).toContain("q=failover");
        const card = output().querySelector("li.card.verso-search-result") as HTMLElement;
        expect(card).not.toBeNull();
        const link = card.querySelector(".verso-search-hit a") as HTMLAnchorElement;
        expect(link.getAttribute("href")).toBe("/documents/guides/failover.md");
        expect(link.textContent).toBe("guides/failover.md");
        expect(card.querySelector(".verso-search-anchor")?.textContent).toContain("Timeouts");
        expect(card.querySelector(".verso-search-excerpt")?.textContent).toContain("SmartWAN");
    });

    it("does not query below the minimum length and clears stale output", async (): Promise<void> => {
        const fetchMock = vi.fn().mockResolvedValue(searchResponse([aResult]));
        vi.stubGlobal("fetch", fetchMock);
        uninstall = installSearchPage();
        output().innerHTML = "<p>stale</p>";

        type("f");
        await vi.advanceTimersByTimeAsync(300);

        expect(fetchMock).not.toHaveBeenCalled();
        expect(output().textContent).toBe("");
    });

    it("shows the clear button while there is text, and clears everything on click", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(searchResponse([aResult])));
        uninstall = installSearchPage();

        type("failover");
        expect(clearButton().hidden).toBe(false);
        await vi.advanceTimersByTimeAsync(300);
        expect(output().querySelector(".verso-search-result")).not.toBeNull();

        clearButton().dispatchEvent(new MouseEvent("click", { bubbles: true }));
        expect(queryInput().value).toBe("");
        expect(clearButton().hidden).toBe(true);
        expect(output().textContent).toBe("");
    });

    it("renders the unreachable-server notice when the query fails", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new TypeError("Failed to fetch")));
        uninstall = installSearchPage();

        type("failover");
        await vi.advanceTimersByTimeAsync(300);

        expect(output().querySelector(".verso-search-error")?.textContent).toContain("Couldn’t reach the server");
    });

    it("renders the indexing-pending notice ahead of the results", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(searchResponse([aResult], 3)));
        uninstall = installSearchPage();

        type("failover");
        await vi.advanceTimersByTimeAsync(300);

        expect(output().querySelector(".verso-search-pending")?.textContent).toContain("3 page(s) pending");
        expect(output().querySelector(".verso-search-result")).not.toBeNull();
    });

    it("prevents the form submit and searches immediately instead", async (): Promise<void> => {
        const fetchMock = vi.fn().mockResolvedValue(searchResponse([aResult]));
        vi.stubGlobal("fetch", fetchMock);
        uninstall = installSearchPage();

        queryInput().value = "failover";
        const submit = new Event("submit", { bubbles: true, cancelable: true });
        document.querySelector(".verso-search-form")?.dispatchEvent(submit);
        await vi.advanceTimersByTimeAsync(0);

        expect(submit.defaultPrevented).toBe(true);
        expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    it("keeps the page URL in step with the query", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(searchResponse([aResult])));
        uninstall = installSearchPage();

        type("failover");
        await vi.advanceTimersByTimeAsync(300);
        expect(window.location.search).toBe("?q=failover");
    });

    it("stops responding once uninstalled", async (): Promise<void> => {
        const fetchMock = vi.fn().mockResolvedValue(searchResponse([aResult]));
        vi.stubGlobal("fetch", fetchMock);
        uninstall = installSearchPage();
        uninstall();
        uninstall = null;

        type("failover");
        await vi.advanceTimersByTimeAsync(300);
        expect(fetchMock).not.toHaveBeenCalled();
    });
});
