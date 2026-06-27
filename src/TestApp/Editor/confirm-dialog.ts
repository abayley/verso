// A themed confirmation dialog (Web Awesome `<wa-dialog>`) used in place of `window.confirm`,
// so destructive actions (delete, move) match the editor theme rather than the browser chrome.
// The dialog is created on demand, appended to <body>, opened, and removed once dismissed.
// Resolves true when the confirm button is chosen, false on cancel / Escape / overlay dismiss.

export interface ConfirmOptions {
    /** The dialog heading (its `label`). */
    title: string;
    /** The body text explaining what will happen. */
    message: string;
    /** The confirm button's text (default "Confirm"). */
    confirmLabel?: string;
    /** The cancel button's text (default "Cancel"). */
    cancelLabel?: string;
    /** When true the confirm button is styled as destructive (red). */
    danger?: boolean;
}

/** Shows a themed confirmation dialog and resolves to the user's choice. */
export function themedConfirm(options: ConfirmOptions): Promise<boolean> {
    return new Promise<boolean>((resolve): void => {
        const dialog = document.createElement("wa-dialog");
        dialog.setAttribute("label", options.title);
        dialog.className = "markdown-editor__confirm";

        const message = document.createElement("p");
        message.className = "markdown-editor__confirm-message";
        message.textContent = options.message;

        const cancel = document.createElement("wa-button");
        cancel.setAttribute("slot", "footer");
        cancel.setAttribute("appearance", "outlined");
        cancel.textContent = options.cancelLabel ?? "Cancel";

        const confirm = document.createElement("wa-button");
        confirm.setAttribute("slot", "footer");
        confirm.setAttribute("appearance", "filled");
        confirm.setAttribute("variant", options.danger === true ? "danger" : "brand");
        confirm.textContent = options.confirmLabel ?? "Confirm";

        let settled = false;
        const settle = (result: boolean): void => {
            if (settled) {
                return;
            }
            settled = true;
            resolve(result);
            // Drive the close animation; the element is removed on `wa-after-hide`.
            (dialog as unknown as { open: boolean }).open = false;
        };

        cancel.addEventListener("click", (): void => settle(false));
        confirm.addEventListener("click", (): void => settle(true));
        // Escape, the close button, or an overlay click all dismiss the dialog -> treat as cancel.
        dialog.addEventListener("wa-hide", (): void => {
            if (!settled) {
                settled = true;
                resolve(false);
            }
        });
        dialog.addEventListener("wa-after-hide", (): void => dialog.remove());

        dialog.append(message, cancel, confirm);
        document.body.append(dialog);
        (dialog as unknown as { open: boolean }).open = true;
        // Focus the confirm action once the dialog has shown.
        dialog.addEventListener("wa-after-show", (): void => confirm.focus(), { once: true });
    });
}
