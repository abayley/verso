/** Delay before a cold tooltip appears on hover/focus. */
const showDelayMilliseconds = 500;

/** Grace period before a tooltip hides after the pointer/focus leaves. */
const hideDelayMilliseconds = 250;

/** Unique-id source for tooltip targets, document-wide across editor instances. */
let tooltipTargetSequence = 0;

/**
 * The editor's shared toolbar tooltip (RFC-0002), extracted from the custom
 * element as a plain controller. It owns the single tooltip element, the show and
 * hide delays, and warm retargeting between controls: once a tooltip is showing
 * (or about to hide), moving to another control retargets it immediately rather
 * than waiting out the show delay again.
 */
export class ToolbarTooltipController {
    private readonly tooltip: HTMLElement;
    private readonly showDelay: number;
    private showTimeout: number | null = null;
    private hideTimeout: number | null = null;

    constructor(showDelay: number = showDelayMilliseconds) {
        this.showDelay = showDelay;
        this.tooltip = document.createElement("wa-tooltip");
        this.tooltip.className = "markdown-editor__tooltip";
        this.tooltip.setAttribute("trigger", "manual");
    }

    /** The shared tooltip element, appended once by the host. */
    public element(): HTMLElement {
        return this.tooltip;
    }

    /** Registers a control: assigns an id and tooltip text and wires show/hide. */
    public register(target: HTMLElement, label: string, shortcut: string | null = null): void {
        const tooltipId = `markdown-editor-control-${++tooltipTargetSequence}`;
        const tooltipText = shortcut ? `${label} (${shortcut})` : label;

        target.id = target.id || tooltipId;
        target.dataset["tooltipText"] = tooltipText;
        target.addEventListener("pointerover", (): void => this.show(target));
        target.addEventListener("focusin", (): void => this.show(target));
        target.addEventListener("pointerout", (): void => this.scheduleHide());
        target.addEventListener("focusout", (): void => this.scheduleHide());
    }

    /** Hides the tooltip immediately and clears its timers (e.g. on disconnect). */
    public hide(): void {
        this.cancelShow();
        this.cancelHide();
        this.tooltip.removeAttribute("open");
    }

    /** Shows or schedules the tooltip for a target control. */
    private show(target: HTMLElement): void {
        const tooltipText = target.dataset["tooltipText"];

        if (!tooltipText) {
            return;
        }

        const warm = this.isVisible() || this.hideTimeout !== null;

        this.cancelHide();
        this.cancelShow();

        if (warm) {
            this.open(target, tooltipText);
            return;
        }

        this.showTimeout = window.setTimeout((): void => {
            this.showTimeout = null;
            this.open(target, tooltipText);
        }, this.showDelay);
    }

    /** Opens the tooltip on a target control. */
    private open(target: HTMLElement, tooltipText: string): void {
        this.tooltip.setAttribute("for", target.id);
        this.tooltip.textContent = tooltipText;
        this.tooltip.setAttribute("open", "");
    }

    /** Hides the tooltip after the grace period. */
    private scheduleHide(): void {
        this.cancelShow();

        if (!this.isVisible() || this.hideTimeout !== null) {
            return;
        }

        this.hideTimeout = window.setTimeout((): void => {
            this.hideTimeout = null;
            this.hide();
        }, hideDelayMilliseconds);
    }

    private isVisible(): boolean {
        return this.tooltip.hasAttribute("open");
    }

    private cancelShow(): void {
        if (this.showTimeout === null) {
            return;
        }

        window.clearTimeout(this.showTimeout);
        this.showTimeout = null;
    }

    private cancelHide(): void {
        if (this.hideTimeout === null) {
            return;
        }

        window.clearTimeout(this.hideTimeout);
        this.hideTimeout = null;
    }
}
