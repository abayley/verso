import { html, LitElement } from "lit";
import { chromeButton, chromeIcon } from "./chrome.js";
import type { VisualTableCommand } from "./tiptap-visual-editor.js";

/** A column alignment the controls can apply. */
type TableAlign = "left" | "center" | "right";

/** Detail of the `table-command` event dispatched by the controls. */
export interface TableCommandEventDetail {
    command: VisualTableCommand;
}

/** Detail of the `table-align` event dispatched by the controls. */
export interface TableAlignEventDetail {
    align: TableAlign;
}

const STRUCTURE_BUTTONS: Array<{ command: VisualTableCommand; label: string }> = [
    { command: "row-after", label: "Add row" },
    { command: "row-delete", label: "Delete row" },
    { command: "column-after", label: "Add column" },
    { command: "column-delete", label: "Delete column" },
];

const ALIGN_BUTTONS: Array<{ align: TableAlign; icon: string; label: string }> = [
    { align: "left", icon: "align-left", label: "Align left" },
    { align: "center", icon: "align-center", label: "Align centre" },
    { align: "right", icon: "align-right", label: "Align right" },
];

/**
 * The internal Lit view for the floating table controls. Each button dispatches a table command or
 * alignment event for the floating surfaces module to route to the editor.
 */
export class TableControlsElement extends LitElement {
    /** Renders into the light DOM so the page's Basecoat styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Processes any pending render synchronously for the owning floating surfaces module. */
    public flush(): void {
        this.performUpdate();
    }

    /** Dispatches a structural table command to the host element. */
    private emitCommand(command: VisualTableCommand): void {
        this.dispatchEvent(
            new CustomEvent<TableCommandEventDetail>("table-command", {
                bubbles: true,
                composed: true,
                detail: { command },
            }),
        );
    }

    /** Dispatches a column-alignment change to the host element. */
    private emitAlign(align: TableAlign): void {
        this.dispatchEvent(
            new CustomEvent<TableAlignEventDetail>("table-align", {
                bubbles: true,
                composed: true,
                detail: { align },
            }),
        );
    }

    protected override render(): unknown {
        return html`
            <div class="markdown-editor__button-group" role="group" aria-label="Table rows and columns">
                ${STRUCTURE_BUTTONS.map((button) =>
                    chromeButton("quiet", button.label, {
                        ariaLabel: button.label,
                        tooltip: button.label,
                        onClick: (): void => this.emitCommand(button.command),
                    }),
                )}
            </div>
            <div class="markdown-editor__button-group" role="group" aria-label="Column alignment">
                ${ALIGN_BUTTONS.map((button) =>
                    chromeButton("icon", chromeIcon(button.icon), {
                        ariaLabel: button.label,
                        tooltip: button.label,
                        onClick: (): void => this.emitAlign(button.align),
                    }),
                )}
            </div>
            ${chromeButton("icon", chromeIcon("trash"), {
                ariaLabel: "Delete table",
                tooltip: "Delete table",
                onClick: (): void => this.emitCommand("delete"),
            })}
        `;
    }
}

if (!customElements.get("markdown-table-controls")) {
    customElements.define("markdown-table-controls", TableControlsElement);
}
