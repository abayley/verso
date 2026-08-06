import { html, LitElement } from "lit";
import { badgeStyle, COMMON_BADGE_COLOURS } from "./badge-syntax.js";
import { type CalloutKind, calloutTitle, isCalloutKind } from "./callout.js";
import { chromeButton, chromeDropdown, chromeIcon, initBasecoat } from "./chrome.js";
import {
    BLOCK_STYLES,
    blockLabel,
    INLINE_COMMANDS,
    inlineShortcut,
    preventDefault,
    STRUCTURE_COMMANDS,
} from "./editor-toolbar-shared.js";
import type { VisualInlineStyle, VisualStructureStyle } from "./tiptap-visual-editor.js";

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
export type InsertStructureKind = "table" | "gfm-alert" | "collapsible";

/** Detail of the `command-insert-structure` event: the block construct to insert, plus the callout kind. */
export interface CommandInsertStructureEventDetail {
    kind: InsertStructureKind;
    /** For `kind: "gfm-alert"`, which Callout kind to insert. */
    gfmAlertKind?: CalloutKind | undefined;
}

/** The Callout kinds offered by the command bar, in its established menu order. */
const CALLOUT_MENU_ITEMS = (["note", "warning", "important", "tip", "caution"] as const).map((value: CalloutKind) => ({
    label: calloutTitle(value),
    value,
}));

/** The block-insert command buttons (table, callout, collapsible), in toolbar order. */
const INSERT_COMMANDS: { kind: InsertStructureKind; label: string; icon: string }[] = [
    { kind: "table", label: "Insert table", icon: "table" },
    { kind: "collapsible", label: "Insert collapsible", icon: "chevrons-down-up" },
];

/**
 * The persistent command bar (style dropdown, inline/structure button groups, save button), rendered
 * declaratively with Lit over the Basecoat chrome helpers (RFC-0035). It owns no editor state: the host
 * drives it through reactive properties and each control dispatches a `command-*` event the host routes
 * to the editor commands. The save button is a native form submit; the host reflects the save-state
 * controller's view onto its label and disabled flag.
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

    constructor() {
        super();
        this.blockStyle = "paragraph";
        this.commandsDisabled = false;
        this.saveLabel = "Save";
        this.saveDisabled = true;
    }

    /** Renders into the light DOM so the page's Basecoat styles apply. */
    protected override createRenderRoot(): HTMLElement {
        return this;
    }

    /** Processes any pending render synchronously, so the host's imperative property writes apply at once. */
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

    /** Dispatches the chosen callout type for the host to insert. */
    private readonly handleCalloutSelect = (kind: string): void => {
        if (isCalloutKind(kind)) {
            this.emitInsertStructure("gfm-alert", kind);
        }
    };

    /** Dispatches a request to insert a block construct (table, callout, collapsible) for the host to run. */
    private emitInsertStructure(kind: InsertStructureKind, gfmAlertKind?: CalloutKind): void {
        this.dispatchEvent(
            new CustomEvent<CommandInsertStructureEventDetail>("command-insert-structure", {
                bubbles: true,
                composed: true,
                detail: { gfmAlertKind, kind },
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
        // Two wrap groups rather than one flat row: as flex items they wrap as units, so the
        // bar's first break always falls between them -- before Badge -- instead of shedding
        // buttons one at a time as the pane narrows. Wide enough for both, and they sit on one
        // line exactly as a flat row would.
        return html`
            <div class="markdown-editor__command-row" role="none">
            ${chromeDropdown({
                id: "command-bar-style",
                className: "markdown-editor__style-dropdown",
                side: "top",
                intent: "quiet",
                trigger: html`${blockLabel(this.blockStyle)} ${chromeIcon("chevron-down")}`,
                triggerClassName: "markdown-editor__button markdown-editor__style-trigger",
                triggerAriaLabel: "Block style",
                triggerTooltip: "Paragraph",
                triggerDisabled: this.commandsDisabled,
                onTriggerMouseDown: preventDefault,
                items: BLOCK_STYLES.map((style) => ({
                    value: style.value,
                    label: style.label,
                    checked: style.value === this.blockStyle,
                })),
                onSelect: this.handleStyleSelect,
            })}
            <div class="markdown-editor__button-group" role="group">
                ${INLINE_COMMANDS.map((command) =>
                    chromeButton("icon", chromeIcon(command.icon), {
                        className: "markdown-editor__button markdown-editor__inline-button",
                        ariaLabel: command.label,
                        tooltip: `${command.label} (${inlineShortcut(command)})`,
                        disabled: this.commandsDisabled,
                        onMouseDown: preventDefault,
                        onClick: (): void => this.emitInline(command.style),
                    }),
                )}
            </div>
            <div class="markdown-editor__button-group" role="group">
                ${STRUCTURE_COMMANDS.map((command) =>
                    chromeButton("icon", chromeIcon(command.icon), {
                        className: "markdown-editor__button markdown-editor__structure-button",
                        ariaLabel: command.label,
                        tooltip: command.label,
                        onMouseDown: preventDefault,
                        onClick: (): void => this.emitStructure(command.style),
                    }),
                )}
            </div>
            </div>
            <div class="markdown-editor__command-row" role="none">
            ${chromeDropdown({
                id: "command-bar-badge",
                className: "markdown-editor__badge-dropdown",
                side: "top",
                intent: "quiet",
                trigger: html`Badge ${chromeIcon("chevron-down")}`,
                triggerClassName: "markdown-editor__button markdown-editor__badge-trigger",
                triggerAriaLabel: "Badge",
                triggerTooltip: "Badge colour",
                triggerDisabled: this.commandsDisabled,
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
            ${chromeDropdown({
                id: "command-bar-callout",
                className: "markdown-editor__callout-dropdown",
                side: "top",
                intent: "icon",
                trigger: chromeIcon("info"),
                triggerClassName: "markdown-editor__button markdown-editor__callout-trigger",
                triggerAriaLabel: "Insert callout",
                triggerTooltip: "Insert callout",
                triggerDisabled: this.commandsDisabled,
                onTriggerMouseDown: preventDefault,
                items: CALLOUT_MENU_ITEMS,
                onSelect: this.handleCalloutSelect,
            })}
            <div class="markdown-editor__button-group" role="group">
                ${INSERT_COMMANDS.map((command) =>
                    chromeButton("icon", chromeIcon(command.icon), {
                        className: "markdown-editor__button markdown-editor__insert-button",
                        ariaLabel: command.label,
                        tooltip: command.label,
                        onMouseDown: preventDefault,
                        onClick: (): void => this.emitInsertStructure(command.kind),
                    }),
                )}
            </div>
            <div class="markdown-editor__button-group" role="group">
                ${chromeButton("icon", chromeIcon("image"), {
                    className: "markdown-editor__button markdown-editor__attachment-button",
                    ariaLabel: "Insert image or file",
                    tooltip: "Insert image or file",
                    onMouseDown: preventDefault,
                    onClick: (): void => this.emitInsertAttachment(),
                })}
            </div>
            ${chromeButton("quiet", this.saveLabel, {
                className: "markdown-editor__button markdown-editor__save-button",
                ariaLabel: "Save",
                tooltip: "Save",
                submit: true,
                disabled: this.saveDisabled,
            })}
            </div>
        `;
    }
}

if (!customElements.get("markdown-command-bar")) {
    customElements.define("markdown-command-bar", CommandBarElement);
}
