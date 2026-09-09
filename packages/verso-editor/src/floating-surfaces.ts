import { BubbleToolbarElement } from "./bubble-toolbar-element.js";
import type {
    CommandBadgeEventDetail,
    CommandBlockStyleEventDetail,
    CommandInlineEventDetail,
    CommandStructureEventDetail,
} from "./command-bar-element.js";
import { SlashMenuElement, type SlashSelectEventDetail } from "./slash-menu-element.js";
import {
    type TableAlignEventDetail,
    type TableCommandEventDetail,
    TableControlsElement,
} from "./table-controls-element.js";
import type { VisualInlineStyle, VisualStructureStyle, VisualTableCommand } from "./tiptap-visual-editor.js";

const overlayGap = 8;

/** A table column alignment exposed by the floating table controls. */
export type TableAlignment = "left" | "center" | "right";

/** State rendered by the selection bubble surface. */
interface BubbleSurfaceState {
    activeStyles: readonly VisualInlineStyle[];
    blockStyle: string;
}

/** Editor actions dispatched by the floating surfaces. */
export interface FloatingSurfacesHandlers {
    applyBadge(value: string): void;
    applyBlockStyle(style: string): void;
    applyTableAlignment(align: TableAlignment): void;
    runTableCommand(command: VisualTableCommand): void;
    toggleInlineStyle(style: VisualInlineStyle): void;
    toggleStructure(style: VisualStructureStyle): void;
}

/** A stateful surface that can be shown at an anchor or hidden. */
export interface BubbleSurface {
    showAt(anchor: DOMRect, state: BubbleSurfaceState): void;
    hide(): void;
}

/** One command displayed by the slash surface. */
export interface SlashCommand {
    label: string;
    children?: readonly SlashCommand[];
    run?: () => void;
}

interface SlashMenuCommand extends SlashCommand {
    back?: boolean;
}

/** The slash command surface. */
export interface SlashSurface {
    showAt(anchor: DOMRect, commands: readonly SlashCommand[]): void;
    hide(): void;
}

/** A surface that can be shown at an anchor or hidden. */
export interface TableSurface {
    showAt(anchor: DOMRect): void;
    hide(): void;
}

/** Owns the editor's floating surfaces and their synchronous display protocol. */
export class FloatingSurfaces {
    private readonly bubbleElement: BubbleToolbarElement;
    private readonly slashElement: SlashMenuElement;
    private readonly tableElement: TableControlsElement;
    private slashAnchor: DOMRect | null = null;
    private slashRoot: readonly SlashCommand[] = [];
    private slashCommands: readonly SlashMenuCommand[] = [];
    private slashStack: Array<readonly SlashMenuCommand[]> = [];
    private slashIndex = 0;
    public readonly bubble: BubbleSurface;
    public readonly slash: SlashSurface;
    public readonly table: TableSurface;
    private readonly handleSlashKeydown = (event: KeyboardEvent): void => {
        if (this.slashElement.hidden) {
            return;
        }

        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            event.stopPropagation();
            const delta = event.key === "ArrowDown" ? 1 : -1;
            this.slashIndex = (this.slashIndex + delta + this.slashCommands.length) % this.slashCommands.length;
            this.renderSlashMenu();
        } else if (event.key === "Enter") {
            event.preventDefault();
            event.stopPropagation();
            this.selectSlashItem(this.slashIndex);
        } else if (event.key === "ArrowLeft" && this.slashStack.length > 0) {
            event.preventDefault();
            event.stopPropagation();
            this.exitSlashSubmenu();
        } else if (event.key === "Escape") {
            event.preventDefault();
            event.stopPropagation();

            if (this.slashStack.length > 0) {
                this.exitSlashSubmenu();
            } else {
                this.slash.hide();
            }
        }
    };

    constructor(
        private readonly host: HTMLElement,
        handlers: FloatingSurfacesHandlers,
    ) {
        this.bubbleElement = this.createBubbleElement(handlers);
        this.bubble = {
            hide: (): void => {
                this.bubbleElement.hidden = true;
            },
            showAt: (anchor: DOMRect, state: BubbleSurfaceState): void => {
                this.bubbleElement.blockStyle = state.blockStyle;
                this.bubbleElement.activeStyles = state.activeStyles;
                this.bubbleElement.flush();
                this.bubbleElement.hidden = false;
                this.position(this.bubbleElement, anchor);
            },
        };
        this.slashElement = this.createSlashElement();
        this.slash = {
            hide: (): void => {
                this.host.removeEventListener("keydown", this.handleSlashKeydown, true);
                this.slashElement.hidden = true;
                this.slashIndex = 0;
                this.slashStack = [];
                this.slashCommands = this.slashRoot;
            },
            showAt: (anchor: DOMRect, commands: readonly SlashCommand[]): void => {
                if (this.slashElement.hidden) {
                    this.slashIndex = 0;
                    this.slashRoot = commands;
                    this.slashCommands = commands;
                    this.host.addEventListener("keydown", this.handleSlashKeydown, true);
                }

                this.slashAnchor = anchor;
                this.renderSlashMenu();
                this.slashElement.hidden = false;
                this.position(this.slashElement, anchor);
            },
        };
        this.tableElement = this.createTableElement(handlers);
        this.table = {
            hide: (): void => {
                this.tableElement.hidden = true;
            },
            showAt: (anchor: DOMRect): void => {
                this.tableElement.flush();
                this.tableElement.hidden = false;
                this.position(this.tableElement, anchor);
            },
        };
    }

    /** Creates the internal bubble view and routes its editor actions. */
    private createBubbleElement(handlers: FloatingSurfacesHandlers): BubbleToolbarElement {
        const element = new BubbleToolbarElement();
        element.className = "markdown-editor__bubble";
        element.setAttribute("role", "toolbar");
        element.hidden = true;
        element.addEventListener("command-block-style", (event: Event): void => {
            handlers.applyBlockStyle((event as CustomEvent<CommandBlockStyleEventDetail>).detail.style);
        });
        element.addEventListener("command-inline", (event: Event): void => {
            handlers.toggleInlineStyle((event as CustomEvent<CommandInlineEventDetail>).detail.style);
        });
        element.addEventListener("command-structure", (event: Event): void => {
            handlers.toggleStructure((event as CustomEvent<CommandStructureEventDetail>).detail.style);
        });
        element.addEventListener("command-badge", (event: Event): void => {
            handlers.applyBadge((event as CustomEvent<CommandBadgeEventDetail>).detail.value);
        });

        return element;
    }

    /** Creates the internal slash menu view and routes pointer selection. */
    private createSlashElement(): SlashMenuElement {
        const element = new SlashMenuElement();
        element.className = "markdown-editor__slash-menu";
        element.setAttribute("role", "listbox");
        element.hidden = true;
        element.addEventListener("slash-select", (event: Event): void => {
            this.selectSlashItem((event as CustomEvent<SlashSelectEventDetail>).detail.index);
        });

        return element;
    }

    /** Creates the internal table controls view and routes its editor actions. */
    private createTableElement(handlers: FloatingSurfacesHandlers): TableControlsElement {
        const element = new TableControlsElement();
        element.className = "markdown-editor__table-controls";
        element.hidden = true;
        element.addEventListener("table-command", (event: Event): void => {
            handlers.runTableCommand((event as CustomEvent<TableCommandEventDetail>).detail.command);
        });
        element.addEventListener("table-align", (event: Event): void => {
            handlers.applyTableAlignment((event as CustomEvent<TableAlignEventDetail>).detail.align);
        });

        return element;
    }

    /** Adds the owned surface elements to the host. */
    public mount(): void {
        this.host.append(this.bubbleElement, this.slashElement, this.tableElement);
    }

    /** Positions an overlay near an anchor without covering it. */
    public position(overlay: HTMLElement, anchor: DOMRect): void {
        const hostRect = this.host.getBoundingClientRect();
        const overlayRect = overlay.getBoundingClientRect();
        const preferredTop = anchor.bottom - hostRect.top + overlayGap;
        const fallbackTop = anchor.top - hostRect.top - overlayRect.height - overlayGap;
        const availableBelow = window.innerHeight - anchor.bottom;
        const top =
            availableBelow >= overlayRect.height + overlayGap ? preferredTop : Math.max(overlayGap, fallbackTop);
        const preferredLeft = anchor.left - hostRect.left;
        const maxLeft = Math.max(overlayGap, hostRect.width - overlayRect.width - overlayGap);
        const left = Math.max(overlayGap, Math.min(preferredLeft, maxLeft));

        overlay.style.left = `${left}px`;
        overlay.style.top = `${top}px`;
    }

    /** Renders the current slash command level and highlighted item synchronously. */
    private renderSlashMenu(): void {
        this.slashElement.items = this.slashCommands.map((command) =>
            command.children ? `${command.label} ›` : command.label,
        );
        this.slashElement.activeIndex = this.slashIndex;
        this.slashElement.flush();
    }

    /** Runs one displayed slash command and closes the surface. */
    private selectSlashItem(index: number): void {
        const command = this.slashCommands[index];

        if (!command) {
            return;
        }

        if (command.back) {
            this.exitSlashSubmenu();
        } else if (command.children) {
            this.enterSlashSubmenu(command.children);
        } else if (command.run) {
            command.run();
            this.slash.hide();
        }
    }

    /** Opens one slash command submenu and keeps it anchored to the same caret. */
    private enterSlashSubmenu(children: readonly SlashCommand[]): void {
        this.slashStack.push(this.slashCommands);
        this.slashCommands = [{ back: true, label: "‹ Back" }, ...children];
        this.slashIndex = 0;
        this.refreshSlashMenu();
    }

    /** Returns from a slash command submenu to its parent level. */
    private exitSlashSubmenu(): void {
        const parent = this.slashStack.pop();

        if (!parent) {
            return;
        }

        this.slashCommands = parent;
        this.slashIndex = 0;
        this.refreshSlashMenu();
    }

    /** Re-renders a changed slash command level and restores its anchor position. */
    private refreshSlashMenu(): void {
        this.renderSlashMenu();

        if (this.slashAnchor) {
            this.position(this.slashElement, this.slashAnchor);
        }
    }
}
