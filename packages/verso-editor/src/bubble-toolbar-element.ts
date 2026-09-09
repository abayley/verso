import { html, LitElement } from "lit";
import { badgeStyle, COMMON_BADGE_COLOURS } from "./badge-syntax.js";
import { chromeButton, chromeDropdown, chromeIcon, initBasecoat } from "./chrome.js";
import type {
    CommandBadgeEventDetail,
    CommandBlockStyleEventDetail,
    CommandInlineEventDetail,
    CommandStructureEventDetail,
} from "./command-bar-element.js";
import {
    BLOCK_STYLES,
    blockLabel,
    INLINE_COMMANDS,
    inlineShortcut,
    preventDefault,
    STRUCTURE_COMMANDS,
} from "./editor-toolbar-shared.js";
import type { VisualInlineStyle, VisualStructureStyle } from "./tiptap-visual-editor.js";

/**
 * The structural commands offered on a selection. A horizontal rule replaces the selected block
 * rather than transforming it, so it stays on the command bar and slash menu only.
 */
const BUBBLE_STRUCTURE_COMMANDS = STRUCTURE_COMMANDS.filter((command) => command.style !== "thematic-break");

/**
 * The internal Lit view for the Studio selection bubble toolbar. The floating surfaces module supplies
 * the current block and inline styles, and routes its command events to the editor.
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

    constructor() {
        super();
        this.blockStyle = "paragraph";
        this.activeStyles = [];
    }

    /** Renders into the light DOM so the page's Basecoat styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Processes any pending render synchronously for the owning floating surfaces module. */
    public flush(): void {
        this.performUpdate();
    }

    /** Initialises any Basecoat components this render produced (spike contract). */
    protected override updated(): void {
        initBasecoat();
    }

    /** Dispatches the chosen block style for the host to validate and apply. */
    private readonly handleStyleSelect = (style: string): void => {
        this.dispatchEvent(
            new CustomEvent<CommandBlockStyleEventDetail>("command-block-style", {
                bubbles: true,
                composed: true,
                detail: { style },
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
    private readonly handleBadgeSelect = (value: string): void => {
        this.dispatchEvent(
            new CustomEvent<CommandBadgeEventDetail>("command-badge", {
                bubbles: true,
                composed: true,
                detail: { value },
            }),
        );
    };

    protected override render(): unknown {
        return html`
            ${chromeDropdown({
                id: "bubble-style",
                className: "markdown-editor__bubble-style",
                intent: "quiet",
                trigger: html`${blockLabel(this.blockStyle)} ${chromeIcon("chevron-down")}`,
                triggerClassName: "markdown-editor__button markdown-editor__bubble-style-trigger",
                triggerAriaLabel: "Block style",
                triggerTooltip: "Paragraph",
                onTriggerMouseDown: preventDefault,
                items: BLOCK_STYLES.map((style) => ({
                    value: style.value,
                    label: style.label,
                    checked: style.value === this.blockStyle,
                })),
                onSelect: this.handleStyleSelect,
            })}
            ${INLINE_COMMANDS.map((command) =>
                chromeButton("icon", chromeIcon(command.icon), {
                    className: "markdown-editor__button markdown-editor__bubble-button",
                    ariaLabel: command.label,
                    tooltip: `${command.label} (${inlineShortcut(command)})`,
                    pressed: this.activeStyles.includes(command.style),
                    onMouseDown: preventDefault,
                    onClick: (): void => this.emitInline(command.style),
                }),
            )}
            ${BUBBLE_STRUCTURE_COMMANDS.map((command) =>
                chromeButton("icon", chromeIcon(command.icon), {
                    className: "markdown-editor__button markdown-editor__bubble-button",
                    ariaLabel: command.label,
                    tooltip: command.label,
                    onMouseDown: preventDefault,
                    onClick: (): void => this.emitStructure(command.style),
                }),
            )}
            ${chromeDropdown({
                id: "bubble-badge",
                className: "markdown-editor__bubble-badge",
                intent: "quiet",
                trigger: html`Badge ${chromeIcon("chevron-down")}`,
                triggerClassName: "markdown-editor__button markdown-editor__bubble-badge-trigger",
                triggerAriaLabel: "Badge",
                triggerTooltip: "Badge colour",
                onTriggerMouseDown: preventDefault,
                items: [
                    ...COMMON_BADGE_COLOURS.map((colour) => ({
                        value: colour,
                        label: html`<span class="badge" style=${badgeStyle(colour)}>${colour}</span>`,
                    })),
                    { value: "remove", label: "Remove badge" },
                ],
                onSelect: this.handleBadgeSelect,
            })}
        `;
    }
}

if (!customElements.get("markdown-bubble-toolbar")) {
    customElements.define("markdown-bubble-toolbar", BubbleToolbarElement);
}
