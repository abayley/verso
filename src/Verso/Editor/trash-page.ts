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

/** Removes a restored row; when the last one goes, swaps the table for the empty-state text. */
function removeRow(button: HTMLButtonElement): void {
    const row = button.closest("tr");
    const tbody = row?.parentElement ?? null;
    row?.remove();
    if (tbody !== null && tbody.querySelectorAll("tr").length === 0) {
        const scroll = document.querySelector(".verso-trash-scroll");
        if (scroll !== null) {
            const empty = document.createElement("p");
            empty.textContent = "Trash is empty.";
            scroll.replaceWith(empty);
        }
    }
}
