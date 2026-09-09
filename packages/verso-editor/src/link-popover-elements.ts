import { html, LitElement } from "lit";
import { chromeButton, chromeIcon } from "./chrome.js";
import { preventDefault } from "./editor-toolbar-shared.js";

/**
 * The link target editor (RFC-0002), rendered declaratively with Lit. It owns no state: the
 * LinkPopoverController shows, positions, and hides it, reads and writes the target through `value`,
 * focuses it through `focusInput()`, and listens for the `link-apply` / `link-cancel` events. Enter and
 * Escape inside the input emit the same events.
 */
export class LinkEditorElement extends LitElement {
    /** Renders into the light DOM so the page's Basecoat styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** The current link target text. */
    public get value(): string {
        return this.inputElement?.value ?? "";
    }

    public set value(target: string) {
        const input = this.inputElement;

        if (input) {
            input.value = target;
        }
    }

    /** Focuses the link target input. */
    public focusInput(): void {
        this.inputElement?.focus();
    }

    private get inputElement(): HTMLInputElement | null {
        return this.querySelector<HTMLInputElement>(".markdown-editor__link-target");
    }

    private emit(name: "link-apply" | "link-cancel"): void {
        this.dispatchEvent(new CustomEvent(name, { bubbles: true, composed: true }));
    }

    private readonly handleKeydown = (event: KeyboardEvent): void => {
        if (event.key === "Enter") {
            event.preventDefault();
            this.emit("link-apply");
        }

        if (event.key === "Escape") {
            event.preventDefault();
            this.emit("link-cancel");
        }
    };

    protected override render(): unknown {
        return html`
            <input
                class="input markdown-editor__link-target"
                type="url"
                placeholder="Link target"
                @keydown=${this.handleKeydown}
            />
            ${chromeButton("quiet", "Apply", {
                className: "markdown-editor__button markdown-editor__link-apply",
                ariaLabel: "Apply",
                tooltip: "Apply",
                onClick: (): void => this.emit("link-apply"),
            })}
            ${chromeButton("quiet", "Cancel", {
                className: "markdown-editor__button markdown-editor__link-cancel",
                ariaLabel: "Cancel",
                tooltip: "Cancel",
                onClick: (): void => this.emit("link-cancel"),
            })}
        `;
    }
}

/**
 * The existing-link hover actions (RFC-0002), rendered declaratively with Lit. It owns no state: the
 * LinkPopoverController shows, positions, and hides it, and listens for the `link-edit` / `link-remove`
 * events to edit or remove the hovered link.
 */
export class LinkActionsElement extends LitElement {
    /** Renders into the light DOM so the page's Basecoat styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    private emit(name: "link-edit" | "link-remove"): void {
        this.dispatchEvent(new CustomEvent(name, { bubbles: true, composed: true }));
    }

    protected override render(): unknown {
        return html`
            ${chromeButton("icon", chromeIcon("pencil"), {
                className: "markdown-editor__button markdown-editor__link-edit",
                ariaLabel: "Edit link",
                tooltip: "Edit link",
                onMouseDown: preventDefault,
                onClick: (): void => this.emit("link-edit"),
            })}
            ${chromeButton("icon", chromeIcon("link-off"), {
                className: "markdown-editor__button markdown-editor__link-remove",
                ariaLabel: "Remove link",
                tooltip: "Remove link",
                onMouseDown: preventDefault,
                onClick: (): void => this.emit("link-remove"),
            })}
        `;
    }
}

if (!customElements.get("markdown-link-editor")) {
    customElements.define("markdown-link-editor", LinkEditorElement);
}

if (!customElements.get("markdown-link-actions")) {
    customElements.define("markdown-link-actions", LinkActionsElement);
}
