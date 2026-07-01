import { html, LitElement } from "lit";
import { badgeStyle, COMMON_BADGE_COLOURS } from "./badge-syntax.js";
import type {
    CommandBadgeEventDetail,
    CommandBlockStyleEventDetail,
    CommandInlineEventDetail,
    CommandStructureEventDetail,
} from "./command-bar-element.js";
import {
    BLOCK_STYLES,
    blockLabel,
    elementValue,
    INLINE_COMMANDS,
    inlineShortcut,
    preventDefault,
    STRUCTURE_COMMANDS,
    type WaDropdownSelectEvent,
} from "./editor-toolbar-shared.js";
import type { VisualInlineStyle, VisualStructureStyle } from "./tiptap-visual-editor.js";
import type { ToolbarTooltipController } from "./toolbar-tooltip-controller.js";

/**
 * The Studio selection bubble toolbar (block-style dropdown + inline command buttons), rendered
 * declaratively with Lit. It owns no editor state: the host shows, positions, and hides it, drives the
 * block-style label and the active inline marks through reactive properties, and routes the bubble's
 * `command-block-style` / `command-inline` events to the same editor commands the command bar uses.
 */
export class BubbleToolbarElement extends LitElement {
    static override properties = {
        blockStyle: { attribute: false },
        activeStyles: { attribute: false },
    };

    /** The current block style value; reflected onto the bubble's style trigger and checked item. */
    declare blockStyle: string;
    /** The inline styles currently active at the selection; reflected onto the button active state. */
    declare activeStyles: readonly VisualInlineStyle[];
    /** The shared toolbar tooltip; set by the host before connection. */
    tooltipController: ToolbarTooltipController | null = null;

    constructor() {
        super();
        this.blockStyle = "paragraph";
        this.activeStyles = [];
    }

    /** Renders into the light DOM so the editor's global Web Awesome styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Processes any pending render synchronously, so the host can position the bubble against fresh layout. */
    public flush(): void {
        this.performUpdate();
    }

    /** Registers the rendered controls with the shared tooltip once, after the first render. */
    protected override firstUpdated(): void {
        const trigger = this.querySelector<HTMLElement>(".markdown-editor__bubble-style-trigger");

        if (trigger) {
            this.tooltipController?.register(trigger, "Paragraph");
        }

        for (const command of INLINE_COMMANDS) {
            const button = this.querySelector<HTMLElement>(
                `.markdown-editor__bubble-button[data-inline-style="${command.style}"]`,
            );

            if (button) {
                this.tooltipController?.register(button, command.label, inlineShortcut(command));
            }
        }

        for (const command of STRUCTURE_COMMANDS) {
            const button = this.querySelector<HTMLElement>(
                `.markdown-editor__bubble-button[data-structure-style="${command.style}"]`,
            );

            if (button) {
                this.tooltipController?.register(button, command.label);
            }
        }

        const badge = this.querySelector<HTMLElement>(".markdown-editor__bubble-badge-trigger");

        if (badge) {
            this.tooltipController?.register(badge, "Badge colour");
        }
    }

    /** Dispatches the chosen block style for the host to validate and apply. */
    private readonly handleStyleSelect = (event: Event): void => {
        const item = (event as WaDropdownSelectEvent).detail.item;

        if (!(item instanceof HTMLElement)) {
            return;
        }

        this.dispatchEvent(
            new CustomEvent<CommandBlockStyleEventDetail>("command-block-style", {
                bubbles: true,
                composed: true,
                detail: { style: elementValue(item) },
            }),
        );
    };

    /** Dispatches an inline-style toggle to the host. */
    private emitInline(style: VisualInlineStyle): void {
        this.dispatchEvent(
            new CustomEvent<CommandInlineEventDetail>("command-inline", {
                bubbles: true,
                composed: true,
                detail: { style },
            }),
        );
    }

    /** Dispatches a structural-style toggle to the host. */
    private emitStructure(style: VisualStructureStyle): void {
        this.dispatchEvent(
            new CustomEvent<CommandStructureEventDetail>("command-structure", {
                bubbles: true,
                composed: true,
                detail: { style },
            }),
        );
    }

    /** Dispatches the chosen badge colour (or "remove") for the host to apply to the selection. */
    private readonly handleBadgeSelect = (event: Event): void => {
        const item = (event as WaDropdownSelectEvent).detail.item;

        if (!(item instanceof HTMLElement)) {
            return;
        }

        this.dispatchEvent(
            new CustomEvent<CommandBadgeEventDetail>("command-badge", {
                bubbles: true,
                composed: true,
                detail: { value: elementValue(item) },
            }),
        );
    };

    protected override render(): unknown {
        return html`
            <wa-dropdown
                class="markdown-editor__bubble-style"
                aria-label="Block style"
                size="s"
                @wa-select=${this.handleStyleSelect}
            >
                <wa-button
                    slot="trigger"
                    class="markdown-editor__button markdown-editor__bubble-style-trigger"
                    appearance="plain"
                    size="s"
                    type="button"
                    aria-label="Paragraph"
                    with-caret
                >${blockLabel(this.blockStyle)}</wa-button>
                ${BLOCK_STYLES.map(
                    (style) => html`
                        <wa-dropdown-item value=${style.value} ?checked=${style.value === this.blockStyle}>
                            ${style.label}
                        </wa-dropdown-item>
                    `,
                )}
            </wa-dropdown>
            ${INLINE_COMMANDS.map(
                (command) => html`
                    <wa-button
                        class="markdown-editor__button markdown-editor__bubble-button ${
                            this.activeStyles.includes(command.style) ? "markdown-editor__bubble-button--active" : ""
                        }"
                        appearance="plain"
                        size="s"
                        type="button"
                        aria-label=${command.label}
                        data-inline-style=${command.style}
                        @mousedown=${preventDefault}
                        @click=${(): void => this.emitInline(command.style)}
                    >
                        <wa-icon
                            class="markdown-editor__button-icon"
                            name=${command.icon}
                            variant="solid"
                            label=${command.label}
                        ></wa-icon>
                    </wa-button>
                `,
            )}
            ${STRUCTURE_COMMANDS.map(
                (command) => html`
                    <wa-button
                        class="markdown-editor__button markdown-editor__bubble-button"
                        appearance="plain"
                        size="s"
                        type="button"
                        aria-label=${command.label}
                        data-structure-style=${command.style}
                        @mousedown=${preventDefault}
                        @click=${(): void => this.emitStructure(command.style)}
                    >
                        <wa-icon
                            class="markdown-editor__button-icon"
                            name=${command.icon}
                            variant="solid"
                            label=${command.label}
                        ></wa-icon>
                    </wa-button>
                `,
            )}
            <wa-dropdown
                class="markdown-editor__bubble-badge"
                aria-label="Badge colour"
                size="s"
                @wa-select=${this.handleBadgeSelect}
            >
                <wa-button
                    slot="trigger"
                    class="markdown-editor__button markdown-editor__bubble-badge-trigger"
                    appearance="plain"
                    size="s"
                    type="button"
                    aria-label="Badge"
                    with-caret
                    @mousedown=${preventDefault}
                >Badge</wa-button>
                ${COMMON_BADGE_COLOURS.map(
                    (colour) => html`
                        <wa-dropdown-item value=${colour}>
                            <span class="badge" style=${badgeStyle(colour)}>${colour}</span>
                        </wa-dropdown-item>
                    `,
                )}
                <wa-dropdown-item value="remove">Remove badge</wa-dropdown-item>
            </wa-dropdown>
        `;
    }
}

if (!customElements.get("markdown-bubble-toolbar")) {
    customElements.define("markdown-bubble-toolbar", BubbleToolbarElement);
}
