import { html, LitElement } from "lit";
import { badgeStyle, COMMON_BADGE_COLOURS } from "./badge-syntax.js";
import {
    BLOCK_STYLES,
    blockLabel,
    elementValue,
    INLINE_COMMANDS,
    inlineShortcut,
    preventDefault,
    type WaDropdownSelectEvent,
} from "./editor-toolbar-shared.js";
import type { VisualInlineStyle, VisualStructureStyle } from "./tiptap-visual-editor.js";
import type { ToolbarTooltipController } from "./toolbar-tooltip-controller.js";

/** Detail of the `command-block-style` event: the raw block style value the host validates. */
export interface CommandBlockStyleEventDetail {
    style: string;
}

/** Detail of the `command-inline` event: the inline style to toggle. */
export interface CommandInlineEventDetail {
    style: VisualInlineStyle;
}

/** Detail of the `command-structure` event: the structural style to toggle. */
export interface CommandStructureEventDetail {
    style: VisualStructureStyle;
}

/** Detail of the `command-badge` event: a colour to apply, or "remove" to clear the badge. */
export interface CommandBadgeEventDetail {
    value: string;
}

/** A block construct the command bar can insert (table / callout / collapsible). */
export type InsertStructureKind = "table" | "admonition" | "collapsible";

/** Detail of the `command-insert-structure` event: the block construct to insert. */
export interface CommandInsertStructureEventDetail {
    kind: InsertStructureKind;
}

/** The structural command buttons, in toolbar order (specific to the persistent command bar). */
const STRUCTURE_COMMANDS: { style: VisualStructureStyle; label: string; icon: string }[] = [
    { style: "bullet-list", label: "Bullet List", icon: "list" },
    { style: "ordered-list", label: "Ordered List", icon: "list-ol" },
    { style: "blockquote", label: "Blockquote", icon: "quote-left" },
    { style: "code-block", label: "Code Block", icon: "file-code" },
    { style: "thematic-break", label: "Horizontal rule", icon: "window-minimize" },
];

/** The block-insert command buttons (table, callout, collapsible), in toolbar order. */
const INSERT_COMMANDS: { kind: InsertStructureKind; label: string; icon: string }[] = [
    { kind: "table", label: "Insert table", icon: "table" },
    { kind: "admonition", label: "Insert callout", icon: "circle-info" },
    { kind: "collapsible", label: "Insert collapsible", icon: "chevron-down" },
];

/**
 * The persistent command bar (style dropdown, inline/structure button groups, save button), rendered
 * declaratively with Lit. It owns no editor state: the host drives it through reactive properties and
 * each control dispatches a `command-*` event the host routes to the editor commands. The save button is
 * a native form submit; the host reflects the save-state controller's view onto its label and disabled flag.
 */
export class CommandBarElement extends LitElement {
    static override properties = {
        blockStyle: { attribute: false },
        commandsDisabled: { attribute: false },
        saveLabel: { attribute: false },
        saveDisabled: { attribute: false },
    };

    /** The current block style value; reflected onto the dropdown trigger and checked item. */
    declare blockStyle: string;
    /** Whether the style trigger and inline buttons are disabled (no active editor). */
    declare commandsDisabled: boolean;
    /** The save button label reported by the save-state controller. */
    declare saveLabel: string;
    /** Whether the save button is disabled (clean or saving). */
    declare saveDisabled: boolean;
    /** The shared toolbar tooltip; set by the host before connection. */
    tooltipController: ToolbarTooltipController | null = null;

    constructor() {
        super();
        this.blockStyle = "paragraph";
        this.commandsDisabled = false;
        this.saveLabel = "Save";
        this.saveDisabled = true;
    }

    /** Renders into the light DOM so the editor's global Web Awesome styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Processes any pending render synchronously, so the host's imperative property writes apply at once. */
    public flush(): void {
        this.performUpdate();
    }

    /** Registers the rendered controls with the shared tooltip once, after the first render. */
    protected override firstUpdated(): void {
        const trigger = this.querySelector<HTMLElement>(".markdown-editor__style-trigger");

        if (trigger) {
            this.tooltipController?.register(trigger, "Paragraph");
        }

        for (const command of INLINE_COMMANDS) {
            const button = this.querySelector<HTMLElement>(
                `.markdown-editor__inline-button[data-inline-style="${command.style}"]`,
            );

            if (button) {
                this.tooltipController?.register(button, command.label, inlineShortcut(command));
            }
        }

        for (const command of STRUCTURE_COMMANDS) {
            const button = this.querySelector<HTMLElement>(
                `.markdown-editor__structure-button[data-structure-style="${command.style}"]`,
            );

            if (button) {
                this.tooltipController?.register(button, command.label);
            }
        }

        for (const command of INSERT_COMMANDS) {
            const button = this.querySelector<HTMLElement>(
                `.markdown-editor__insert-button[data-insert-kind="${command.kind}"]`,
            );

            if (button) {
                this.tooltipController?.register(button, command.label);
            }
        }

        const badge = this.querySelector<HTMLElement>(".markdown-editor__badge-trigger");

        if (badge) {
            this.tooltipController?.register(badge, "Badge colour");
        }

        const attachment = this.querySelector<HTMLElement>(".markdown-editor__attachment-button");

        if (attachment) {
            this.tooltipController?.register(attachment, "Insert image or file");
        }

        const save = this.querySelector<HTMLElement>(".markdown-editor__save-button");

        if (save) {
            this.tooltipController?.register(save, "Save");
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

    /** Dispatches a request to insert a block construct (table, callout, collapsible) for the host to run. */
    private emitInsertStructure(kind: InsertStructureKind): void {
        this.dispatchEvent(
            new CustomEvent<CommandInsertStructureEventDetail>("command-insert-structure", {
                bubbles: true,
                composed: true,
                detail: { kind },
            }),
        );
    }

    /** Dispatches a request to insert an image or file attachment (the host opens the file picker). */
    private emitInsertAttachment(): void {
        this.dispatchEvent(
            new CustomEvent<undefined>("command-insert-attachment", {
                bubbles: true,
                composed: true,
                detail: undefined,
            }),
        );
    }

    protected override render(): unknown {
        return html`
            <wa-dropdown
                class="markdown-editor__style-dropdown"
                aria-label="Block style"
                size="small"
                @wa-select=${this.handleStyleSelect}
            >
                <wa-button
                    slot="trigger"
                    class="markdown-editor__button markdown-editor__style-trigger"
                    appearance="plain"
                    size="small"
                    type="button"
                    aria-label="Paragraph"
                    with-caret
                    ?disabled=${this.commandsDisabled}
                >${blockLabel(this.blockStyle)}</wa-button>
                ${BLOCK_STYLES.map(
                    (style) => html`
                        <wa-dropdown-item value=${style.value} ?checked=${style.value === this.blockStyle}>
                            ${style.label}
                        </wa-dropdown-item>
                    `,
                )}
            </wa-dropdown>
            <wa-button-group class="markdown-editor__button-group">
                ${INLINE_COMMANDS.map(
                    (command) => html`
                        <wa-button
                            class="markdown-editor__button markdown-editor__inline-button"
                            appearance="plain"
                            size="small"
                            type="button"
                            aria-label=${command.label}
                            data-inline-style=${command.style}
                            ?disabled=${this.commandsDisabled}
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
            </wa-button-group>
            <wa-button-group class="markdown-editor__button-group">
                ${STRUCTURE_COMMANDS.map(
                    (command) => html`
                        <wa-button
                            class="markdown-editor__button markdown-editor__structure-button"
                            appearance="plain"
                            size="small"
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
            </wa-button-group>
            <wa-dropdown
                class="markdown-editor__badge-dropdown"
                aria-label="Badge colour"
                size="small"
                @wa-select=${this.handleBadgeSelect}
            >
                <wa-button
                    slot="trigger"
                    class="markdown-editor__button markdown-editor__badge-trigger"
                    appearance="plain"
                    size="small"
                    type="button"
                    aria-label="Badge"
                    with-caret
                    ?disabled=${this.commandsDisabled}
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
            <wa-button-group class="markdown-editor__button-group">
                ${INSERT_COMMANDS.map(
                    (command) => html`
                        <wa-button
                            class="markdown-editor__button markdown-editor__insert-button"
                            appearance="plain"
                            size="small"
                            type="button"
                            aria-label=${command.label}
                            data-insert-kind=${command.kind}
                            @mousedown=${preventDefault}
                            @click=${(): void => this.emitInsertStructure(command.kind)}
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
            </wa-button-group>
            <wa-button-group class="markdown-editor__button-group">
                <wa-button
                    class="markdown-editor__button markdown-editor__attachment-button"
                    appearance="plain"
                    size="small"
                    type="button"
                    aria-label="Insert image or file"
                    @mousedown=${preventDefault}
                    @click=${(): void => this.emitInsertAttachment()}
                >
                    <wa-icon
                        class="markdown-editor__button-icon"
                        name="image"
                        variant="solid"
                        label="Insert image or file"
                    ></wa-icon>
                </wa-button>
            </wa-button-group>
            <wa-button
                class="markdown-editor__button markdown-editor__save-button"
                type="submit"
                appearance="plain"
                size="small"
                aria-label="Save"
                ?disabled=${this.saveDisabled}
            >${this.saveLabel}</wa-button>
        `;
    }
}

if (!customElements.get("markdown-command-bar")) {
    customElements.define("markdown-command-bar", CommandBarElement);
}
