import { html, LitElement } from "lit";
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
 * The floating table-editing controls, rendered declaratively with Lit (the RFC's Lit-adoption
 * trigger). It owns no editor state: each button dispatches a `table-command` or `table-align`
 * event that the host element routes to the Tiptap table commands.
 */
export class TableControlsElement extends LitElement {
    /** Renders into the light DOM so the editor's global Web Awesome styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
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
            <wa-button-group label="Table rows and columns">
                ${STRUCTURE_BUTTONS.map(
                    (button) => html`
                        <wa-button
                            appearance="plain"
                            size="s"
                            title=${button.label}
                            @click=${(): void => this.emitCommand(button.command)}
                        >
                            ${button.label}
                        </wa-button>
                    `,
                )}
            </wa-button-group>
            <wa-button-group label="Column alignment">
                ${ALIGN_BUTTONS.map(
                    (button) => html`
                        <wa-button
                            appearance="plain"
                            size="s"
                            title=${button.label}
                            @click=${(): void => this.emitAlign(button.align)}
                        >
                            <wa-icon name=${button.icon} label=${button.label}></wa-icon>
                        </wa-button>
                    `,
                )}
            </wa-button-group>
            <wa-button
                appearance="plain"
                size="s"
                title="Delete table"
                @click=${(): void => this.emitCommand("delete")}
            >
                <wa-icon name="trash" label="Delete table"></wa-icon>
            </wa-button>
        `;
    }
}

if (!customElements.get("markdown-table-controls")) {
    customElements.define("markdown-table-controls", TableControlsElement);
}
