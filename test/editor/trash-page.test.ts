import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installTrashPurge } from "../../src/Verso/Editor/trash-page.js";

let uninstall: (() => void) | null = null;

/** Mounts a one-row trash page (with the empty-trash control) and installs the purge handler. */
function mountTrashPage(confirmAnswer: boolean): ReturnType<typeof vi.fn> {
    const fetchMock = vi.fn(async (): Promise<Response> => new Response("{}", { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    document.body.innerHTML = [
        '<button class="verso-trash-empty">Empty trash</button>',
        '<div class="verso-trash-scroll"><table class="verso-trash"><tbody><tr><td>',
        '<button class="verso-trash-delete" data-delete-id="3" data-delete-path="sec/page.md">Delete forever</button>',
        "</td></tr></tbody></table></div>",
    ].join("");
    uninstall = installTrashPurge({ confirm: async (): Promise<boolean> => confirmAnswer });

    return fetchMock;
}

describe("trash page purge controls", (): void => {
    beforeEach((): void => {
        document.body.replaceChildren();
    });

    afterEach((): void => {
        uninstall?.();
        uninstall = null;
        vi.restoreAllMocks();
    });

    it("given a delete-forever button, when clicked and confirmed, then it DELETEs the entry and drops the row", async (): Promise<void> => {
        const fetchMock = mountTrashPage(true);

        (document.querySelector(".verso-trash-delete") as HTMLElement).click();
        await new Promise((resolve) => setTimeout(resolve));

        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(String(fetchMock.mock.calls[0]?.[0])).toBe("/trash/3");
        expect((fetchMock.mock.calls[0]?.[1] as RequestInit).method).toBe("DELETE");
        expect(document.querySelector("tr")).toBeNull();
    });

    it("given the empty-trash button, when clicked and confirmed, then it DELETEs /trash and shows the empty state", async (): Promise<void> => {
        const fetchMock = mountTrashPage(true);

        (document.querySelector(".verso-trash-empty") as HTMLElement).click();
        await new Promise((resolve) => setTimeout(resolve));

        expect(fetchMock).toHaveBeenCalledTimes(1);
        expect(String(fetchMock.mock.calls[0]?.[0])).toBe("/trash");
        expect((fetchMock.mock.calls[0]?.[1] as RequestInit).method).toBe("DELETE");
        expect(document.querySelector(".verso-trash-scroll")).toBeNull();
        expect(document.querySelector(".verso-trash-empty")).toBeNull();
        expect(document.body.textContent).toContain("Trash is empty.");
    });

    it("given a delete-forever button, when the confirmation is declined, then nothing is sent", async (): Promise<void> => {
        const fetchMock = mountTrashPage(false);

        (document.querySelector(".verso-trash-delete") as HTMLElement).click();
        await new Promise((resolve) => setTimeout(resolve));

        expect(fetchMock).not.toHaveBeenCalled();
        expect(document.querySelector("tr")).not.toBeNull();
    });
});
