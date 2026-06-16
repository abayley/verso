import { html, LitElement } from "lit";
import { preventDefault } from "./editor-toolbar-shared.js";

/** Detail of the `slash-select` event: the index of the chosen command. */
export interface SlashSelectEventDetail {
    index: number;
}

/**
 * The Studio slash command menu, rendered declaratively with Lit. It owns no editor state: the host
 * supplies the command labels, shows/positions/hides the menu, tracks and drives the highlighted index
 * through the `activeIndex` property (for both pointer and keyboard navigation), and runs the chosen
 * command when the menu dispatches `slash-select`.
 */
export class SlashMenuElement extends LitElement {
    static override properties = {
        items: { attribute: false },
        activeIndex: { attribute: false },
    };

    /** The command labels, in menu order. */
    declare items: readonly string[];
    /** The index of the highlighted command. */
    declare activeIndex: number;

    constructor() {
        super();
        this.items = [];
        this.activeIndex = 0;
    }

    /** Renders into the light DOM so the editor's global Web Awesome styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Processes any pending render synchronously, so the host can position the menu against fresh layout. */
    public flush(): void {
        this.performUpdate();
    }

    /** Dispatches the chosen command index to the host. */
    private emitSelect(index: number): void {
        this.dispatchEvent(
            new CustomEvent<SlashSelectEventDetail>("slash-select", {
                bubbles: true,
                composed: true,
                detail: { index },
            }),
        );
    }

    protected override render(): unknown {
        return html`
            ${this.items.map(
                (label, index) => html`
                    <button
                        type="button"
                        class="markdown-editor__slash-item ${
                            index === this.activeIndex ? "markdown-editor__slash-item--active" : ""
                        }"
                        @mousedown=${preventDefault}
                        @click=${(): void => this.emitSelect(index)}
                    >${label}</button>
                `,
            )}
        `;
    }
}

if (!customElements.get("markdown-slash-menu")) {
    customElements.define("markdown-slash-menu", SlashMenuElement);
}
