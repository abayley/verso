import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { installUndoApply } from "../../src/Verso/Editor/undo-page.js";

let uninstall: (() => void) | null = null;

/** Mounts one undo-page row and installs the delegated handler with recording fakes. */
function mountUndoRow(confirmAnswer: boolean): { undoMove: ReturnType<typeof vi.fn>; reloads: number[] } {
    const undoMove = vi.fn(async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }));
    const reloads: number[] = [];

    document.body.innerHTML = [
        "<table><tbody><tr><td>",
        '<button class="verso-undo-apply" data-undo-seq="3" data-undo-from="a" data-undo-to="b/a">Undo</button>',
        "</td></tr></tbody></table>",
    ].join("");
    uninstall = installUndoApply({
        client: { undoMove },
        confirm: async (): Promise<boolean> => confirmAnswer,
        reload: (): void => {
            reloads.push(1);
        },
    });

    return { undoMove, reloads };
}

/** Lets the handler's async chain settle. */
async function settle(): Promise<void> {
    await new Promise((resolve) => setTimeout(resolve));
}

describe("undo page", (): void => {
    beforeEach((): void => {
        document.body.replaceChildren();
    });

    afterEach((): void => {
        uninstall?.();
        uninstall = null;
        vi.restoreAllMocks();
    });

    it("given an undo row, when its button is clicked and confirmed, then it posts the seq to /undo and reloads", async (): Promise<void> => {
        const { undoMove, reloads } = mountUndoRow(true);

        (document.querySelector(".verso-undo-apply") as HTMLElement).click();
        await settle();

        expect(undoMove).toHaveBeenCalledWith(3);
        expect(reloads).toHaveLength(1);
    });

    it("given an undo row, when the confirmation is declined, then nothing is posted", async (): Promise<void> => {
        const { undoMove, reloads } = mountUndoRow(false);

        (document.querySelector(".verso-undo-apply") as HTMLElement).click();
        await settle();

        expect(undoMove).not.toHaveBeenCalled();
        expect(reloads).toHaveLength(0);
    });
});
