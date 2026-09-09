import { afterEach, beforeEach, describe, expect, it, type Mock, vi } from "vitest";
import { SearchPanel } from "../src/search-panel.js";
import type { SearchResponse, SearchResult, ServerClient, ServerResult } from "../src/server-client.js";

const enabledResult = (results: SearchResult[], pending = 0): ServerResult<SearchResponse> => ({
    ok: true,
    value: { enabled: true, pending, results },
});

/** A recording fake for the panel's server seam. */
interface SearchClientFake {
    searchPages: Mock<ServerClient["searchPages"]>;
}

/** Creates a recording fake for the panel's server seam. */
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

describe("SearchPanel", (): void => {
    beforeEach((): void => {
        vi.useFakeTimers();
    });

    afterEach((): void => {
        vi.restoreAllMocks();
        vi.useRealTimers();
    });

    it("given the server reports search disabled, when the panel connects, then it hides itself", async (): Promise<void> => {
        const client = fakeClient({ ok: true, value: { enabled: false, pending: 0, results: [] } });
        const panel = new SearchPanel(undefined, client);
        await panel.connect();
        expect(panel.element().hidden).toBe(true);
    });

    it("given the server reports search enabled, when the panel connects, then it shows itself", async (): Promise<void> => {
        const client = fakeClient(enabledResult([]));
        const panel = new SearchPanel(undefined, client);
        await panel.connect();
        expect(panel.element().hidden).toBe(false);
    });

    it("given several keystrokes in quick succession, when the debounce elapses, then one query runs and title, anchor and excerpt rows render", async (): Promise<void> => {
        const client = fakeClient(enabledResult([aResult]));
        const panel = new SearchPanel(undefined, client);
        const input = panel.element().querySelector("input") as HTMLInputElement;

        for (const value of ["f", "fa", "fai", "failover"]) {
            input.value = value;
            input.dispatchEvent(new Event("input"));
        }
        await vi.advanceTimersByTimeAsync(300);

        expect(client.searchPages).toHaveBeenCalledTimes(1);
        expect(client.searchPages).toHaveBeenCalledWith("failover", expect.any(AbortSignal));
        const row = panel.dropdownElement().querySelector(".markdown-editor__search-row") as HTMLElement;
        expect(row.querySelector(".markdown-editor__search-title")?.textContent).toBe("Failover Guide");
        expect(row.querySelector(".markdown-editor__search-anchor")?.textContent).toContain("Timeouts");
        expect(row.querySelector(".markdown-editor__search-crumb")?.textContent).toBe("guides");
        expect(row.querySelector(".markdown-editor__search-excerpt")?.textContent).toContain("failover timeouts");
    });

    it("given a result row, when it is clicked with a modifier, then the browser handles the link and no navigation is requested", async (): Promise<void> => {
        const client = fakeClient(enabledResult([aResult]));
        const navigations: string[] = [];
        const panel = new SearchPanel((path: string): void => {
            navigations.push(path);
        }, client);
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        const row = panel.dropdownElement().querySelector(".markdown-editor__search-row") as HTMLAnchorElement;
        expect(row.tagName).toBe("A");
        expect(row.href).toContain("/documents/guides/failover.md");

        const cmdClick = new MouseEvent("click", { metaKey: true, cancelable: true });
        row.dispatchEvent(cmdClick);
        expect(cmdClick.defaultPrevented).toBe(false);
        expect(navigations).toEqual([]);

        const plainClick = new MouseEvent("click", { cancelable: true });
        row.dispatchEvent(plainClick);
        expect(plainClick.defaultPrevented).toBe(true);
        expect(navigations).toEqual(["guides/failover.md"]);
    });

    it("given a result row, when it is clicked plainly, then the panel navigates to that page", async (): Promise<void> => {
        const client = fakeClient(enabledResult([aResult]));
        const navigations: string[] = [];
        const panel = new SearchPanel((path: string): void => {
            navigations.push(path);
        }, client);
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        (panel.dropdownElement().querySelector(".markdown-editor__search-row") as HTMLElement).click();
        expect(navigations).toEqual(["guides/failover.md"]);
    });

    it("given an open dropdown, when Escape is pressed or the query falls too short, then it closes", async (): Promise<void> => {
        const client = fakeClient(enabledResult([aResult]));
        const panel = new SearchPanel(undefined, client);
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);
        const dropdown = panel.dropdownElement();
        expect(dropdown.hidden).toBe(false);

        input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
        expect(dropdown.hidden).toBe(true);

        input.value = "f";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);
        expect(dropdown.hidden).toBe(true);
    });

    it("given an unreachable server, when a query is typed, then the dropdown shows an error message", async (): Promise<void> => {
        const client = fakeClient({ ok: false, message: "Couldn’t reach the server." });
        const panel = new SearchPanel(undefined, client);
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        const dropdown = panel.dropdownElement();
        expect(dropdown.hidden).toBe(false);
        expect(dropdown.querySelector(".markdown-editor__search-error")?.textContent).toBe(
            "Couldn’t reach the server.",
        );
    });

    it("given the indexing queue is busy, when results render, then the pending note is shown", async (): Promise<void> => {
        const client = fakeClient(enabledResult([aResult], 42));
        const panel = new SearchPanel(undefined, client);
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        expect(panel.dropdownElement().querySelector(".markdown-editor__search-pending")?.textContent).toContain("42");
    });
});
