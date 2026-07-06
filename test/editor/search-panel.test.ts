import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SearchPanel } from "../../src/Verso/Editor/search-panel.js";

const enabledResponse = (results: object[], pending = 0): Response =>
    new Response(JSON.stringify({ enabled: true, pending, results }), {
        headers: { "Content-Type": "application/json" },
    });

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

    it("hides itself when the server has search disabled", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response('{"enabled":false}')));
        const panel = new SearchPanel();
        await panel.connect();
        expect(panel.element().hidden).toBe(true);
    });

    it("shows itself when the server has search enabled", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(enabledResponse([])));
        const panel = new SearchPanel();
        await panel.connect();
        expect(panel.element().hidden).toBe(false);
    });

    it("debounces typing into one query and renders title, anchor, and excerpt rows", async (): Promise<void> => {
        const fetchMock = vi.fn().mockResolvedValue(enabledResponse([aResult]));
        vi.stubGlobal("fetch", fetchMock);
        const panel = new SearchPanel();
        const input = panel.element().querySelector("input") as HTMLInputElement;

        for (const value of ["f", "fa", "fai", "failover"]) {
            input.value = value;
            input.dispatchEvent(new Event("input"));
        }
        await vi.advanceTimersByTimeAsync(300);

        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(String(fetchMock.mock.calls[0]?.[0])).toContain("/search?json&q=failover");
        const row = panel.element().querySelector(".markdown-editor__search-row") as HTMLElement;
        expect(row.querySelector(".markdown-editor__search-title")?.textContent).toBe("Failover Guide");
        expect(row.querySelector(".markdown-editor__search-anchor")?.textContent).toContain("Timeouts");
        expect(row.querySelector(".markdown-editor__search-crumb")?.textContent).toBe("guides");
        expect(row.querySelector(".markdown-editor__search-excerpt")?.textContent).toContain("failover timeouts");
    });

    it("renders rows as page links, leaving modified clicks (new tab) to the browser", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(enabledResponse([aResult])));
        const navigations: string[] = [];
        const panel = new SearchPanel((path: string): void => {
            navigations.push(path);
        });
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        const row = panel.element().querySelector(".markdown-editor__search-row") as HTMLAnchorElement;
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

    it("navigates to the clicked result's page", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(enabledResponse([aResult])));
        const navigations: string[] = [];
        const panel = new SearchPanel((path: string): void => {
            navigations.push(path);
        });
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        (panel.element().querySelector(".markdown-editor__search-row") as HTMLElement).click();
        expect(navigations).toEqual(["guides/failover.md"]);
    });

    it("closes the dropdown on Escape and when the query is too short", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(enabledResponse([aResult])));
        const panel = new SearchPanel();
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);
        const dropdown = panel.element().querySelector(".markdown-editor__search-results") as HTMLElement;
        expect(dropdown.hidden).toBe(false);

        input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
        expect(dropdown.hidden).toBe(true);

        input.value = "f";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);
        expect(dropdown.hidden).toBe(true);
    });

    it("shows the indexing-pending note when the queue is busy", async (): Promise<void> => {
        vi.stubGlobal("fetch", vi.fn().mockResolvedValue(enabledResponse([aResult], 42)));
        const panel = new SearchPanel();
        const input = panel.element().querySelector("input") as HTMLInputElement;
        input.value = "failover";
        input.dispatchEvent(new Event("input"));
        await vi.advanceTimersByTimeAsync(300);

        expect(panel.element().querySelector(".markdown-editor__search-pending")?.textContent).toContain("42");
    });
});
