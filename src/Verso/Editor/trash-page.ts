// The server-rendered trash page's Restore buttons (RFC-0028). Wiring them here -- rather than with
// htmx attributes -- means the page carries no runtime dependency on the CDN htmx bundle (a failed load
// left the buttons inert), and restore gets the same themed confirmation as the nav dropdown and delete.

import { themedConfirm } from "./confirm-dialog.js";

/**
 * Handles clicks on the trash page's Restore buttons via a single delegated document listener. Delegation
 * (rather than per-button wiring) is required because the shared bundle loads as a head script that runs
 * before the body's buttons exist; it also matches the tooltip controller's approach. A no-op elsewhere.
 */
export function installTrashRestore(): void {
    document.addEventListener("click", (event): void => {
        const target = event.target instanceof Element ? event.target : null;
        const button = target?.closest<HTMLButtonElement>(".verso-trash-restore[data-restore-id]");
        if (button !== null && button !== undefined) {
            void restoreEntry(button);
        }
    });
}

/** Confirms, POSTs the restore, then removes the row (or the whole list once empty). */
async function restoreEntry(button: HTMLButtonElement): Promise<void> {
    const id = button.dataset["restoreId"];
    if (id === undefined) {
        return;
    }
    const path = button.dataset["restorePath"] ?? "this item";
    const confirmed = await themedConfirm({
        title: "Restore",
        message: `Restore “${path}” to its original location?`,
        confirmLabel: "Restore",
    });
    if (!confirmed) {
        return;
    }
    button.disabled = true;
    try {
        const response = await fetch(`/trash/${encodeURIComponent(id)}`, { method: "POST" });
        if (response.ok) {
            // A restored page returns to its original path: open it. Sections have no page to open,
            // so just drop the row and stay on the trash page.
            if (path.endsWith(".md")) {
                window.location.assign(`/documents/${path.split("/").map(encodeURIComponent).join("/")}`);
            } else {
                removeRow(button);
            }
            return;
        }
    } catch {
        // fall through to the failure path
    }
    button.disabled = false;
    window.alert(`Could not restore “${path}”. Its original location may now be occupied.`);
}

/** Removes a restored or purged row; when the last one goes, swaps the table for the empty-state text. */
function removeRow(button: HTMLButtonElement): void {
    const row = button.closest("tr");
    const tbody = row?.parentElement ?? null;
    row?.remove();
    if (tbody !== null && tbody.querySelectorAll("tr").length === 0) {
        showEmptyState();
    }
}

/** Swaps the trash table (and the empty-trash control) for the empty-state text. */
function showEmptyState(): void {
    document.querySelector(".verso-trash-empty")?.remove();
    const scroll = document.querySelector(".verso-trash-scroll");
    if (scroll !== null) {
        const empty = document.createElement("p");
        empty.textContent = "Trash is empty.";
        scroll.replaceWith(empty);
    }
}

/** The trash page's destructive seams, injectable for tests. */
export interface TrashPurgeDeps {
    /** Asks the user to confirm the permanent delete; resolves true to proceed. */
    confirm: (options: { title: string; message: string; confirmLabel: string }) => Promise<boolean>;
}

const defaultPurgeDeps: TrashPurgeDeps = { confirm: themedConfirm };

/**
 * Handles the trash page's permanent-delete controls -- the per-row "Delete forever" buttons and the
 * page-level "Empty trash" button -- via one delegated document listener (same pattern as the Restore
 * handler above). A no-op on other pages. Returns the listener's remover for tests.
 */
export function installTrashPurge(deps: TrashPurgeDeps = defaultPurgeDeps): () => void {
    const onClick = (event: Event): void => {
        const target = event.target instanceof Element ? event.target : null;
        const deleteButton = target?.closest<HTMLButtonElement>(".verso-trash-delete[data-delete-id]");
        if (deleteButton !== null && deleteButton !== undefined) {
            void deleteEntry(deleteButton, deps);
            return;
        }
        const emptyButton = target?.closest<HTMLButtonElement>(".verso-trash-empty");
        if (emptyButton !== null && emptyButton !== undefined) {
            void emptyTrash(emptyButton, deps);
        }
    };
    document.addEventListener("click", onClick);

    return (): void => document.removeEventListener("click", onClick);
}

/** Confirms, DELETEs one entry, then removes its row. */
async function deleteEntry(button: HTMLButtonElement, deps: TrashPurgeDeps): Promise<void> {
    const id = button.dataset["deleteId"];
    if (id === undefined) {
        return;
    }
    const path = button.dataset["deletePath"] ?? "this item";
    const confirmed = await deps.confirm({
        title: "Delete forever",
        message: `Permanently delete “${path}”? This cannot be undone.`,
        confirmLabel: "Delete forever",
    });
    if (!confirmed) {
        return;
    }
    button.disabled = true;
    try {
        const response = await fetch(`/trash/${encodeURIComponent(id)}`, { method: "DELETE" });
        if (response.ok) {
            removeRow(button);
            return;
        }
    } catch {
        // fall through to the failure path
    }
    button.disabled = false;
    window.alert(`Could not delete “${path}”.`);
}

/** Confirms, DELETEs the whole trash, then swaps in the empty state. */
async function emptyTrash(button: HTMLButtonElement, deps: TrashPurgeDeps): Promise<void> {
    const confirmed = await deps.confirm({
        title: "Empty trash",
        message: "Permanently delete everything in the trash? This cannot be undone.",
        confirmLabel: "Empty trash",
    });
    if (!confirmed) {
        return;
    }
    button.disabled = true;
    try {
        const response = await fetch("/trash", { method: "DELETE" });
        if (response.ok) {
            showEmptyState();
            return;
        }
    } catch {
        // fall through to the failure path
    }
    button.disabled = false;
    window.alert("Could not empty the trash.");
}
