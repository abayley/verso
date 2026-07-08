// A themed confirmation dialog (native <dialog> with Basecoat's dialog styling, RFC-0035) used in
// place of `window.confirm`, so destructive actions (delete, move) match the editor theme rather
// than the browser chrome. The dialog is created on demand, appended to <body>, opened modally,
// and removed once dismissed. Resolves true when the confirm button is chosen, false on cancel /
// Escape / backdrop dismiss.

import { chromeButtonEl } from "./chrome.js";

export interface ConfirmOptions {
    /** The dialog heading. */
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
        const dialog = document.createElement("dialog");
        dialog.className = "dialog markdown-editor__confirm";

        const article = document.createElement("article");

        const header = document.createElement("header");
        const heading = document.createElement("h2");
        heading.textContent = options.title;
        header.append(heading);

        const section = document.createElement("section");
        const message = document.createElement("p");
        message.className = "markdown-editor__confirm-message";
        message.textContent = options.message;
        section.append(message);

        const footer = document.createElement("footer");
        const cancel = chromeButtonEl("outline", options.cancelLabel ?? "Cancel", {});
        const confirm = chromeButtonEl(
            options.danger === true ? "danger" : "primary",
            options.confirmLabel ?? "Confirm",
            {},
        );
        footer.append(cancel, confirm);

        article.append(header, section, footer);
        dialog.append(article);

        let settled = false;
        const settle = (result: boolean): void => {
            if (settled) {
                return;
            }
            settled = true;
            resolve(result);
            dialog.close();
        };

        cancel.addEventListener("click", (): void => settle(false));
        confirm.addEventListener("click", (): void => settle(true));
        // Escape (the native cancel path) dismisses the dialog -> treat as cancel.
        dialog.addEventListener("close", (): void => {
            if (!settled) {
                settled = true;
                resolve(false);
            }

            dialog.remove();
        });

        document.body.append(dialog);
        dialog.showModal();
        confirm.focus();
    });
}
