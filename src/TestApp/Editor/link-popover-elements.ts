import { html, LitElement } from "lit";
import { preventDefault } from "./editor-toolbar-shared.js";
import type { ToolbarTooltipController } from "./toolbar-tooltip-controller.js";

/**
 * The link target editor (RFC-0002), rendered declaratively with Lit. It owns no state: the
 * LinkPopoverController shows, positions, and hides it, reads and writes the target through `value`,
 * focuses it through `focusInput()`, and listens for the `link-apply` / `link-cancel` events. Enter and
 * Escape inside the input emit the same events.
 */
export class LinkEditorElement extends LitElement {
    /** The shared toolbar tooltip; set by the controller before connection. */
    tooltipController: ToolbarTooltipController | null = null;

    /** Renders into the light DOM so the editor's global Web Awesome styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Registers the Apply and Cancel controls with the shared tooltip once, after the first render. */
    protected override firstUpdated(): void {
        const apply = this.querySelector<HTMLElement>(".markdown-editor__link-apply");
        const cancel = this.querySelector<HTMLElement>(".markdown-editor__link-cancel");

        if (apply) {
            this.tooltipController?.register(apply, "Apply");
        }

        if (cancel) {
            this.tooltipController?.register(cancel, "Cancel");
        }
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
                class="markdown-editor__link-target"
                type="url"
                placeholder="Link target"
                @keydown=${this.handleKeydown}
            />
            <wa-button
                class="markdown-editor__button markdown-editor__link-apply"
                appearance="plain"
                size="small"
                type="button"
                aria-label="Apply"
                @click=${(): void => this.emit("link-apply")}
            >Apply</wa-button>
            <wa-button
                class="markdown-editor__button markdown-editor__link-cancel"
                appearance="plain"
                size="small"
                type="button"
                aria-label="Cancel"
                @click=${(): void => this.emit("link-cancel")}
            >Cancel</wa-button>
        `;
    }
}

/**
 * The existing-link hover actions (RFC-0002), rendered declaratively with Lit. It owns no state: the
 * LinkPopoverController shows, positions, and hides it, and listens for the `link-edit` / `link-remove`
 * events to edit or remove the hovered link.
 */
export class LinkActionsElement extends LitElement {
    /** The shared toolbar tooltip; set by the controller before connection. */
    tooltipController: ToolbarTooltipController | null = null;

    /** Renders into the light DOM so the editor's global Web Awesome styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Registers the Edit and Remove controls with the shared tooltip once, after the first render. */
    protected override firstUpdated(): void {
        const edit = this.querySelector<HTMLElement>(".markdown-editor__link-edit");
        const remove = this.querySelector<HTMLElement>(".markdown-editor__link-remove");

        if (edit) {
            this.tooltipController?.register(edit, "Edit link");
        }

        if (remove) {
            this.tooltipController?.register(remove, "Remove link");
        }
    }

    private emit(name: "link-edit" | "link-remove"): void {
        this.dispatchEvent(new CustomEvent(name, { bubbles: true, composed: true }));
    }

    protected override render(): unknown {
        return html`
            <wa-button
                class="markdown-editor__button markdown-editor__link-edit"
                appearance="plain"
                size="small"
                type="button"
                aria-label="Edit link"
                @mousedown=${preventDefault}
                @click=${(): void => this.emit("link-edit")}
            >
                <wa-icon class="markdown-editor__button-icon" name="pencil" variant="solid" label="Edit link"></wa-icon>
            </wa-button>
            <wa-button
                class="markdown-editor__button markdown-editor__link-remove"
                appearance="plain"
                size="small"
                type="button"
                aria-label="Remove link"
                @mousedown=${preventDefault}
                @click=${(): void => this.emit("link-remove")}
            >
                <wa-icon
                    class="markdown-editor__button-icon"
                    name="link-slash"
                    variant="solid"
                    label="Remove link"
                ></wa-icon>
            </wa-button>
        `;
    }
}

if (!customElements.get("markdown-link-editor")) {
    customElements.define("markdown-link-editor", LinkEditorElement);
}

if (!customElements.get("markdown-link-actions")) {
    customElements.define("markdown-link-actions", LinkActionsElement);
}
