// The server-rendered undo page's Undo buttons: the full-page counterpart to the nav dropdown's
// undo picker, wired like trash-page.ts (delegated listener, themed confirmation, plain fetch).

import { themedConfirm } from "./confirm-dialog.js";

/** The undo page's effectful seams, injectable for tests. */
export interface UndoPageDeps {
    /** Asks the user to confirm the undo; resolves true to proceed. */
    confirm: (options: { title: string; message: string; confirmLabel: string }) => Promise<boolean>;
    /** Reloads the page after a successful undo (the log and rows are stale). */
    reload: () => void;
}

const defaultDeps: UndoPageDeps = {
    confirm: themedConfirm,
    reload: (): void => window.location.reload(),
};

/**
 * Handles clicks on the undo page's Undo buttons via a single delegated document listener (the shared
 * bundle loads as a head script that runs before the body's buttons exist). A no-op on other pages.
 * Returns the listener's remover (tests install repeatedly on one shared document).
 */
export function installUndoApply(deps: UndoPageDeps = defaultDeps): () => void {
    const onClick = (event: Event): void => {
        const target = event.target instanceof Element ? event.target : null;
        const button = target?.closest<HTMLButtonElement>(".verso-undo-apply[data-undo-seq]");
        if (button !== null && button !== undefined) {
            void applyUndo(button, deps);
        }
    };
    document.addEventListener("click", onClick);

    return (): void => document.removeEventListener("click", onClick);
}

/** Confirms, POSTs the inverse to /undo, then reloads (the whole log may have shifted). */
async function applyUndo(button: HTMLButtonElement, deps: UndoPageDeps): Promise<void> {
    const seq = button.dataset["undoSeq"];
    if (seq === undefined) {
        return;
    }
    const from = button.dataset["undoFrom"] ?? "its source";
    const to = button.dataset["undoTo"] ?? "its destination";
    const confirmed = await deps.confirm({
        title: "Undo move",
        message: `Undo this move? “${to}” moves back to “${from}”.`,
        confirmLabel: "Undo move",
    });
    if (!confirmed) {
        return;
    }
    button.disabled = true;
    try {
        const response = await fetch("/undo", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({ seq }).toString(),
        });
        if (response.ok) {
            deps.reload();
            return;
        }
    } catch {
        // fall through to the failure path
    }
    button.disabled = false;
    window.alert(`Could not undo the move of “${to}”. The tree may have changed since.`);
}
