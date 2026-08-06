import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installTrashPurge } from "../../src/Verso/Editor/trash-page.js";

let uninstall: (() => void) | null = null;

/** Mounts a one-row trash page with recording server client methods. */
function mountTrashPage(confirmAnswer: boolean): {
    deleteTrashEntry: ReturnType<typeof vi.fn>;
    emptyTrash: ReturnType<typeof vi.fn>;
} {
    const deleteTrashEntry = vi.fn(
        async (): Promise<{ ok: true; value: undefined }> => ({
            ok: true,
            value: undefined,
        }),
    );
    const emptyTrash = vi.fn(async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }));

    document.body.innerHTML = [
        '<button class="verso-trash-empty">Empty trash</button>',
        '<div class="verso-trash-scroll"><table class="verso-trash"><tbody><tr><td>',
        '<button class="verso-trash-delete" data-delete-id="3" data-delete-path="sec/page.md">Delete forever</button>',
        "</td></tr></tbody></table></div>",
    ].join("");
    uninstall = installTrashPurge({
        client: { deleteTrashEntry, emptyTrash },
        confirm: async (): Promise<boolean> => confirmAnswer,
    });

    return { deleteTrashEntry, emptyTrash };
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
        const { deleteTrashEntry } = mountTrashPage(true);

        (document.querySelector(".verso-trash-delete") as HTMLElement).click();
        await new Promise((resolve) => setTimeout(resolve));

        expect(deleteTrashEntry).toHaveBeenCalledWith("3");
        expect(document.querySelector("tr")).toBeNull();
    });

    it("given the empty-trash button, when clicked and confirmed, then it DELETEs /trash and shows the empty state", async (): Promise<void> => {
        const { emptyTrash } = mountTrashPage(true);

        (document.querySelector(".verso-trash-empty") as HTMLElement).click();
        await new Promise((resolve) => setTimeout(resolve));

        expect(emptyTrash).toHaveBeenCalledTimes(1);
        expect(document.querySelector(".verso-trash-scroll")).toBeNull();
        expect(document.querySelector(".verso-trash-empty")).toBeNull();
        expect(document.body.textContent).toContain("Trash is empty.");
    });

    it("given a delete-forever button, when the confirmation is declined, then nothing is sent", async (): Promise<void> => {
        const { deleteTrashEntry } = mountTrashPage(false);

        (document.querySelector(".verso-trash-delete") as HTMLElement).click();
        await new Promise((resolve) => setTimeout(resolve));

        expect(deleteTrashEntry).not.toHaveBeenCalled();
        expect(document.querySelector("tr")).not.toBeNull();
    });
});
