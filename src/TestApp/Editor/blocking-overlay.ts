// A full-viewport modal overlay shown while a slow tree operation (move/delete/undo/restore)
// is in flight. It blocks all interaction -- parts of the UI refresh when the operation
// completes, so the user must not act mid-operation -- and gives an obvious spinner + message,
// unlike the subtle in-nav status line it replaces.

let overlay: HTMLElement | null = null;

/** Shows the blocking overlay with a message (replacing any existing one). */
export function showBlockingOverlay(message: string): void {
    if (!overlay) {
        overlay = document.createElement("div");
        overlay.className = "markdown-editor__blocking-overlay";
        overlay.setAttribute("role", "alertdialog");
        overlay.setAttribute("aria-busy", "true");
        // Swallow interaction while shown (covers the viewport; pointer-events on by default).
        overlay.addEventListener("keydown", (event: KeyboardEvent): void => event.stopPropagation());

        const card = document.createElement("div");
        card.className = "markdown-editor__blocking-card";

        const spinner = document.createElement("wa-spinner");
        spinner.className = "markdown-editor__blocking-spinner";

        const label = document.createElement("span");
        label.className = "markdown-editor__blocking-label";
        overlay.dataset["labelId"] = "blocking-label";
        label.id = "blocking-label";
        overlay.setAttribute("aria-labelledby", "blocking-label");

        card.append(spinner, label);
        overlay.append(card);
        document.body.append(overlay);
    }
    const label = overlay.querySelector(".markdown-editor__blocking-label");
    if (label) {
        label.textContent = message;
    }
}

/** Removes the blocking overlay if present. */
export function hideBlockingOverlay(): void {
    overlay?.remove();
    overlay = null;
}
