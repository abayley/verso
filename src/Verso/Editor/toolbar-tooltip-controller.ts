/**
 * The editor's toolbar tooltips (RFC-0002), reimplemented over Basecoat's
 * CSS-only tooltips (RFC-0035): registering a control now just stamps its
 * data-tooltip attribute; hover/focus behaviour, delays, and placement are
 * the stylesheet's. The class keeps its old surface (register/hide/element)
 * so hosts did not have to change when the wa-tooltip implementation left.
 */
export class ToolbarTooltipController {
    private readonly placeholder: HTMLElement;

    constructor() {
        this.placeholder = document.createElement("span");
        this.placeholder.hidden = true;
        this.placeholder.className = "markdown-editor__tooltip";
    }

    /** A hidden placeholder, kept so hosts that append the element still can. */
    public element(): HTMLElement {
        return this.placeholder;
    }

    /** Registers a control: sets its tooltip text (label plus optional shortcut). */
    public register(target: HTMLElement, label: string, shortcut: string | null = null): void {
        target.setAttribute("data-tooltip", shortcut ? `${label} (${shortcut})` : label);
    }

    /** Kept for the host's disconnect path; CSS tooltips need no teardown. */
    public hide(): void {
        // CSS-only tooltips hide with hover/focus; nothing to tear down.
    }
}
