/**
 * Basecoat chrome helpers for Lit templates (RFC-0035): the TypeScript
 * mirror of Verso.Chrome. Call sites state semantic intent; the mapping to
 * Basecoat's class/data-variant/data-size vocabulary lives here alone, and
 * the dropdown/tab ARIA wiring is derived from one base id (incomplete
 * wiring makes the Basecoat runtime skip a component silently).
 *
 * Spike contract (docs/design/basecoat-lit-spike.md): the attributes the
 * Basecoat runtime mutates (aria-expanded, aria-hidden) are authored as
 * static template text, never Lit bindings, so re-renders cannot clobber
 * runtime state. Components rendered by a Lit element need
 * window.basecoat.initAll() from that element's updated() hook; call
 * initBasecoat() there.
 */

import { html, type TemplateResult } from "lit";
import { ifDefined } from "lit/directives/if-defined.js";

export { NETWORK_ERROR } from "./server-client.js";

export type ButtonIntent = "primary" | "quiet" | "outline" | "icon" | "danger";

export type ButtonOptions = {
    id?: string;
    /** Extra classes merged after "btn" (our BEM test-contract classes). */
    className?: string;
    ariaLabel?: string;
    tooltip?: string;
    disabled?: boolean;
    /** Toggle-button state; omitted for ordinary command buttons. */
    pressed?: boolean;
    /** Renders type="submit" instead of type="button". */
    submit?: boolean;
    onClick?: (event: Event) => void;
    /** Typically preventDefault, so a toolbar press keeps the selection. */
    onMouseDown?: (event: Event) => void;
};

type IntentAttrs = { variant?: string; size: string };

/** The Basecoat attributes for an intent; the only variant vocabulary site. */
function intentAttrs(intent: ButtonIntent): IntentAttrs {
    switch (intent) {
        case "primary":
            return { size: "sm" };
        case "quiet":
            return { variant: "ghost", size: "sm" };
        case "outline":
            return { variant: "outline", size: "sm" };
        case "icon":
            return { variant: "ghost", size: "icon-sm" };
        case "danger":
            return { variant: "destructive", size: "sm" };
    }
}

/** Re-scans for Basecoat components; hosts call this from updated(). */
export function initBasecoat(): void {
    const runtime = (window as { basecoat?: { initAll: () => void } }).basecoat;
    runtime?.initAll();
}

/** A chrome button (non-submitting unless options.submit). */
export function chromeButton(
    intent: ButtonIntent,
    content: TemplateResult | string,
    options: ButtonOptions,
): TemplateResult {
    const attrs = intentAttrs(intent);
    const classes = options.className ? `btn ${options.className}` : "btn";

    return html`<button
        type=${options.submit ? "submit" : "button"}
        class=${classes}
        id=${ifDefined(options.id)}
        data-variant=${ifDefined(attrs.variant)}
        data-size=${attrs.size}
        aria-label=${ifDefined(options.ariaLabel)}
        aria-pressed=${ifDefined(options.pressed === undefined ? undefined : String(options.pressed))}
        data-tooltip=${ifDefined(options.tooltip)}
        ?disabled=${options.disabled ?? false}
        @click=${options.onClick}
        @mousedown=${options.onMouseDown}
    >${content}</button>`;
}

/**
 * An inline icon referencing the external Lucide sprite
 * (static/editor/icons.svg); stroke styling and sizing come from the
 * chrome-icon class.
 */
export function chromeIcon(name: string): TemplateResult {
    return html`<svg class="chrome-icon" aria-hidden="true"><use href="/static/editor/icons.svg#i-${name}"></use></svg>`;
}

type DropdownItem = {
    value: string;
    label: TemplateResult | string;
    /** Marks the currently-selected value (aria-checked on the item). */
    checked?: boolean;
};

export type DropdownOptions = {
    id: string;
    /** Extra classes on the dropdown root (our BEM test-contract classes). */
    className?: string;
    intent: ButtonIntent;
    trigger: TemplateResult | string;
    triggerClassName?: string;
    triggerAriaLabel?: string;
    triggerTooltip?: string;
    triggerDisabled?: boolean;
    /** Which side of the trigger the menu opens (default "bottom"). */
    side?: "top" | "bottom";
    /** Menu alignment along the trigger edge (default "start"). */
    align?: "start" | "center" | "end";
    items: DropdownItem[];
    onSelect: (value: string) => void;
    /** Typically preventDefault on the trigger, keeping the selection. */
    onTriggerMouseDown?: (event: Event) => void;
};

/**
 * A Basecoat dropdown menu with the full id/ARIA wiring derived from the
 * base id. Selection is reported through onSelect with the item's value.
 */
export function chromeDropdown(options: DropdownOptions): TemplateResult {
    const attrs = intentAttrs(options.intent);
    const triggerClasses = options.triggerClassName ? `btn ${options.triggerClassName}` : "btn";
    const rootClasses = options.className ? `dropdown-menu ${options.className}` : "dropdown-menu";

    return html`<div class=${rootClasses} id=${options.id}>
        <button
            type="button"
            class=${triggerClasses}
            id="${options.id}-trigger"
            data-variant=${ifDefined(attrs.variant)}
            data-size=${attrs.size}
            aria-label=${ifDefined(options.triggerAriaLabel)}
            data-tooltip=${ifDefined(options.triggerTooltip)}
            ?disabled=${options.triggerDisabled ?? false}
            aria-haspopup="menu"
            aria-controls="${options.id}-menu"
            aria-expanded="false"
            @mousedown=${options.onTriggerMouseDown}
        >${options.trigger}</button>
        <div
            id="${options.id}-popover"
            data-popover
            aria-hidden="true"
            data-side=${ifDefined(options.side)}
            data-align=${ifDefined(options.align)}
        >
            <div role="menu" id="${options.id}-menu" aria-labelledby="${options.id}-trigger">
                ${options.items.map(
                    (item) =>
                        html`<button
                            type="button"
                            role="menuitem"
                            data-value=${item.value}
                            aria-checked=${ifDefined(item.checked === undefined ? undefined : String(item.checked))}
                            @click=${(): void => options.onSelect(item.value)}
                        >${item.label}</button>`,
                )}
            </div>
        </div>
    </div>`;
}

type TabEntry = { value: string; label: string; selected: boolean };

export type TabsOptions = {
    id: string;
    className?: string;
    ariaLabel?: string;
    entries: TabEntry[];
    onSelect: (value: string) => void;
};

/** A Basecoat line-variant tab strip; clicks report the entry's value. */
export function chromeTabs(options: TabsOptions): TemplateResult {
    const classes = options.className ? `tabs ${options.className}` : "tabs";

    return html`<div class=${classes} id=${options.id}>
        <nav
            role="tablist"
            aria-orientation="horizontal"
            data-variant="line"
            aria-label=${ifDefined(options.ariaLabel)}
        >
            ${options.entries.map(
                (entry) =>
                    html`<button
                        type="button"
                        role="tab"
                        data-value=${entry.value}
                        aria-selected=${entry.selected ? "true" : "false"}
                        tabindex=${entry.selected ? "0" : "-1"}
                        @click=${(): void => options.onSelect(entry.value)}
                    >${entry.label}</button>`,
            )}
        </nav>
    </div>`;
}

/* ------------------------------------------------------------------------
 * Imperative builders, for hosts that assemble DOM directly (the editor
 * element's top bar). Same intent vocabulary and wiring as the Lit helpers.
 * ---------------------------------------------------------------------- */

type ElOptions = {
    className?: string;
    ariaLabel?: string;
    tooltip?: string;
};

/** Applies the shared button attributes for an intent to a button or link. */
function applyIntent(element: HTMLElement, intent: ButtonIntent, options: ElOptions): void {
    const attrs = intentAttrs(intent);

    element.className = options.className ? `btn ${options.className}` : "btn";

    if (attrs.variant !== undefined) {
        element.dataset["variant"] = attrs.variant;
    }

    element.dataset["size"] = attrs.size;

    if (options.ariaLabel !== undefined) {
        element.setAttribute("aria-label", options.ariaLabel);
    }

    if (options.tooltip !== undefined) {
        element.dataset["tooltip"] = options.tooltip;
    }
}

/** An imperative chrome button. */
export function chromeButtonEl(intent: ButtonIntent, label: string, options: ElOptions): HTMLButtonElement {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    applyIntent(button, intent, options);

    return button;
}

/** An imperative chrome link styled as a button (plain navigation). */
export function chromeLinkEl(intent: ButtonIntent, label: string, href: string, options: ElOptions): HTMLAnchorElement {
    const link = document.createElement("a");
    link.href = href;
    link.textContent = label;
    applyIntent(link, intent, options);

    return link;
}

/** An imperative sprite icon (see chromeIcon). */
export function chromeIconEl(name: string): SVGElement {
    const template = document.createElement("template");
    template.innerHTML = `<svg class="chrome-icon" aria-hidden="true"><use href="/static/editor/icons.svg#i-${name}"></use></svg>`;
    const icon = template.content.firstElementChild;

    if (!(icon instanceof SVGElement)) {
        throw new Error("chrome icon template did not parse");
    }

    return icon;
}

/** A dismissible notice alert's handle: the card, its message slot, and the variant switch. */
export interface ChromeAlertHandle {
    root: HTMLDivElement;
    /** The message slot; set its textContent. */
    message: HTMLElement;
    /** The dismiss button (hides the card on click). */
    dismiss: HTMLButtonElement;
    /** Switches the card between the default and destructive look. */
    setDestructive: (on: boolean) => void;
}

/**
 * The heading over a side-panel group -- "Pages" on the navigation tree, "Contents"/"Attachments"/
 * "History" on the metadata pane. The shadcn sidebar's group label: a short row in the panel's text
 * colour at reduced strength, not a shouted uppercase caption.
 */
export function chromePanelHeadingEl(text: string): HTMLElement {
    const heading = document.createElement("h2");
    heading.className = "markdown-editor__panel-heading";
    heading.textContent = text;

    return heading;
}

/** A panel row: the element itself, and the label span that truncates inside it. */
export interface ChromePanelRow<T extends HTMLElement> {
    root: T;
    label: HTMLSpanElement;
}

/**
 * One row of a side panel -- a page in the navigation tree, a contents entry, an attachment, the
 * history link. Both panels build their rows here so the shadcn sidebar menu-button shape (height,
 * padding, radius, gap, hover fill, truncating label) is defined once and cannot drift between them;
 * callers append their own extras (a disclosure chevron, row actions) around the label.
 *
 * The label is a span of its own because the row is a flex container, and a flex container cannot clip
 * its own anonymous text with an ellipsis.
 */
export function chromePanelRowEl<K extends keyof HTMLElementTagNameMap>(
    tag: K,
    options: { label: string; className?: string } = { label: "" },
): ChromePanelRow<HTMLElementTagNameMap[K]> {
    const root = document.createElement(tag);
    root.className = options.className
        ? `markdown-editor__panel-row ${options.className}`
        : "markdown-editor__panel-row";

    if (root instanceof HTMLButtonElement) {
        root.type = "button";
    }

    const label = document.createElement("span");
    label.className = "markdown-editor__panel-row-label";
    label.textContent = options.label;
    root.append(label);

    return { label, root };
}

/**
 * An imperative notice alert (the shadcn alert look): a message section plus an icon dismiss button
 * pinned to the trailing edge. Created hidden; callers fill the message and unhide.
 */
export function chromeAlertEl(options: { className: string; role: string; destructive?: boolean }): ChromeAlertHandle {
    const root = document.createElement("div");
    root.className = `alert ${options.className}`;
    root.setAttribute("role", options.role);
    root.hidden = true;

    const setDestructive = (on: boolean): void => {
        if (on) {
            root.setAttribute("data-variant", "destructive");
        } else {
            root.removeAttribute("data-variant");
        }
    };
    setDestructive(options.destructive ?? false);

    const message = document.createElement("section");
    message.className = "markdown-editor__notice-message";

    const footer = document.createElement("footer");
    const dismiss = chromeButtonEl("icon", "", {
        className: "markdown-editor__notice-dismiss",
        ariaLabel: "Dismiss",
        tooltip: "Dismiss",
    });
    dismiss.append(chromeIconEl("x"));
    dismiss.addEventListener("click", (): void => {
        root.hidden = true;
    });
    footer.append(dismiss);
    root.append(message, footer);

    return { root, message, dismiss, setDestructive };
}

/** One entry of a segmented control: a text label, an icon, or both. */
type SegmentEntry = {
    value: string;
    label: string;
    icon?: string;
    /** Show the icon only, keeping the label as tooltip + aria-label. */
    iconOnly?: boolean;
};

/** A segmented control element: Basecoat line tabs with a value property. */
export interface ChromeSegmentElement extends HTMLDivElement {
    value: string;
    /** Reflects a programmatic value change into the tab states. */
    sync(value: string): void;
}

export type SegmentOptions = {
    className?: string;
    ariaLabel?: string;
    entries: SegmentEntry[];
    /** Joined outline icon buttons (the scheme control) instead of line tabs. */
    joined?: boolean;
};

/**
 * An imperative segmented single-choice control (the mode/width/scheme
 * controls). Renders as a Basecoat line-variant tablist (or a joined outline
 * group for icon entries), maintains a `value` property/attribute, and
 * dispatches a bubbling "change" event on user selection -- the contract the
 * editor host and its tests already speak.
 */
export function chromeSegmentEl(options: SegmentOptions): ChromeSegmentElement {
    const container = document.createElement("div") as ChromeSegmentElement;
    container.className = options.className ?? "";

    const list = document.createElement("nav");
    list.setAttribute("role", "tablist");
    list.setAttribute("aria-orientation", "horizontal");

    if (options.joined) {
        // Text-label entries need auto-width segments; icon-only entries are square.
        const labelled = options.entries.some((entry) => !entry.iconOnly);
        list.className = labelled ? "chrome-segment-joined chrome-segment-joined--labels" : "chrome-segment-joined";
    } else {
        container.classList.add("tabs");
        list.dataset["variant"] = "line";
    }

    if (options.ariaLabel !== undefined) {
        list.setAttribute("aria-label", options.ariaLabel);
    }

    const buttons: HTMLButtonElement[] = [];

    const reflect = (value: string): void => {
        for (const button of buttons) {
            const selected = button.dataset["value"] === value;
            button.setAttribute("aria-selected", selected ? "true" : "false");
            button.tabIndex = selected ? 0 : -1;
        }
    };

    let currentValue = "";

    Object.defineProperty(container, "value", {
        get: (): string => currentValue,
        set: (value: string): void => {
            currentValue = value;
            reflect(value);
        },
    });

    container.sync = (value: string): void => {
        currentValue = value;
        container.setAttribute("value", value);
        reflect(value);
    };

    for (const entry of options.entries) {
        const button = document.createElement("button");
        button.type = "button";
        button.setAttribute("role", "tab");
        button.dataset["value"] = entry.value;
        button.setAttribute("aria-selected", "false");
        button.setAttribute("aria-label", entry.label);
        button.tabIndex = -1;

        if (options.joined) {
            // Icon-only entries render as square icon buttons with a tooltip; entries
            // with a visible label render as compact text segments (no tooltip needed,
            // the label is visible). Both sit in the same joined outline group.
            applyIntent(button, entry.iconOnly ? "icon" : "quiet", entry.iconOnly ? { tooltip: entry.label } : {});
            if (entry.iconOnly) {
                // A joined icon group is a top-bar toolbar at the viewport's top-right: open its
                // tooltips below and aligned to the right edge so they render into the viewport.
                button.setAttribute("data-side", "bottom");
                button.setAttribute("data-align", "end");
            }
            button.setAttribute("role", "tab");
        }

        if (entry.icon !== undefined) {
            button.append(chromeIconEl(entry.icon));
        }

        if (!entry.iconOnly) {
            button.append(entry.label);
        }

        button.addEventListener("click", (): void => {
            container.sync(entry.value);
            container.dispatchEvent(new Event("change", { bubbles: true }));
        });

        buttons.push(button);
        list.append(button);
    }

    container.append(list);

    return container;
}

/** A chrome dropdown element with its trigger label and checked-state sync. */
export interface ChromeDropdownElement extends HTMLDivElement {
    /** Updates the trigger label text (the caret is kept). */
    setTriggerLabel(label: string): void;
    /** Reflects the selected value onto the menu items' checked state. */
    syncChecked(value: string): void;
    /** Replaces the menu items (dynamic menus); wires clicks to onSelect. */
    setItems(items: { value: string; label: string; disabled?: boolean }[]): void;
}

export type DropdownElOptions = {
    id: string;
    /** Extra classes on the dropdown root (our BEM test-contract classes). */
    className?: string;
    intent: ButtonIntent;
    triggerLabel: string;
    triggerClassName?: string;
    ariaLabel?: string;
    /** Suppress the caret icon (compact icon-style triggers). */
    caret?: boolean;
    /** Lift the menu out of the flow, for a trigger inside a clipping scroll container (see pinPopover). */
    pinned?: boolean;
    /** Keep the menu outside the DOM until the trigger is first focused or pressed. */
    deferred?: boolean;
    items: { value: string; label: string; disabled?: boolean }[];
    onSelect: (value: string) => void;
};

/**
 * Pins a dropdown's menu to fixed viewport coordinates just below its trigger, for a trigger that sits
 * inside an `overflow` scroll container: positioned normally the menu is clipped at the container's edge,
 * and -- closed but only visually hidden -- its full height counts towards the container's scrollable
 * area, which puts a scrollbar on a box that has nothing to scroll.
 *
 * `position: fixed` is therefore set once and kept, not applied on open: it is what keeps the closed menu
 * out of the container's overflow. The coordinates are refreshed whenever Basecoat opens the menu (it only
 * toggles `aria-hidden`, so these inline styles survive). Synchronous, not rAF: the position is read from
 * the trigger, which is always laid out, and rAF is throttled to a standstill while the page is hidden.
 */
const POPOVER_MARGIN = 4;

/** The floor on a pinned menu's height: below this it is better to overhang than to be a two-item slot. */
const MIN_POPOVER_HEIGHT = 120;

function pinPopover(popover: HTMLElement, trigger: HTMLElement): void {
    popover.style.position = "fixed";
    popover.style.insetInlineStart = "auto";
    popover.style.insetInlineEnd = "auto";
    popover.style.bottom = "auto";
    // Above the editor pane and the delegated tooltip (z 900), below the blocking overlay (z 1000).
    popover.style.zIndex = "950";

    const reposition = (): void => {
        if (popover.getAttribute("aria-hidden") !== "false") {
            return;
        }

        const rect = trigger.getBoundingClientRect();
        popover.style.left = `${Math.round(rect.left)}px`;
        // Measure the menu unconstrained before deciding where it goes.
        popover.style.maxHeight = "none";
        const wanted = popover.scrollHeight;
        const viewport = document.documentElement.clientHeight;
        const below = viewport - rect.bottom - POPOVER_MARGIN * 2;
        const above = rect.top - POPOVER_MARGIN * 2;
        // Below the trigger by default; above it when the menu does not fit below and there is more room
        // there. Either way the height is capped to the room available and the menu scrolls, so a long
        // list (the code languages) can always be reached to its end.
        const placeAbove = wanted > below && above > below;
        const room = Math.max(placeAbove ? above : below, MIN_POPOVER_HEIGHT);
        const height = Math.min(wanted, room);
        popover.style.maxHeight = `${Math.round(room)}px`;
        popover.style.overflowY = "auto";
        popover.style.top = placeAbove
            ? `${Math.round(rect.top - POPOVER_MARGIN - height)}px`
            : `${Math.round(rect.bottom + POPOVER_MARGIN)}px`;
    };

    new MutationObserver(reposition).observe(popover, { attributes: true, attributeFilter: ["aria-hidden"] });
}

/** An imperative Basecoat dropdown menu (see chromeDropdown for the wiring). */
export function chromeDropdownEl(options: DropdownElOptions): ChromeDropdownElement {
    const root = document.createElement("div") as ChromeDropdownElement;
    root.className = options.className ? `dropdown-menu ${options.className}` : "dropdown-menu";
    root.id = options.id;

    const trigger = document.createElement("button");
    trigger.type = "button";
    trigger.id = `${options.id}-trigger`;
    const triggerOptions: ElOptions = {};

    if (options.triggerClassName !== undefined) {
        triggerOptions.className = options.triggerClassName;
    }

    if (options.ariaLabel !== undefined) {
        triggerOptions.ariaLabel = options.ariaLabel;
    }

    applyIntent(trigger, options.intent, triggerOptions);
    const triggerLabel = document.createElement("span");
    triggerLabel.textContent = options.triggerLabel;
    trigger.append(triggerLabel);

    if (options.caret !== false) {
        trigger.append(chromeIconEl("chevron-down"));
    }
    trigger.setAttribute("aria-haspopup", "menu");
    trigger.setAttribute("aria-controls", `${options.id}-menu`);
    trigger.setAttribute("aria-expanded", "false");

    const popover = document.createElement("div");
    popover.id = `${options.id}-popover`;
    popover.setAttribute("data-popover", "");
    popover.setAttribute("aria-hidden", "true");

    const menu = document.createElement("div");
    menu.setAttribute("role", "menu");
    menu.id = `${options.id}-menu`;
    menu.setAttribute("aria-labelledby", `${options.id}-trigger`);

    let currentItems = options.items;
    let checkedValue: string | undefined;
    let materialised = options.deferred !== true;
    const buildItems = (items: { value: string; label: string; disabled?: boolean }[]): void => {
        menu.replaceChildren();

        for (const item of items) {
            const entry = document.createElement("button");
            entry.type = "button";
            entry.setAttribute("role", "menuitem");
            entry.dataset["value"] = item.value;
            entry.textContent = item.label;

            if (item.disabled === true) {
                entry.disabled = true;
            }

            entry.addEventListener("click", (): void => options.onSelect(item.value));
            menu.append(entry);
        }
    };

    buildItems(materialised ? currentItems : []);
    popover.append(menu);
    root.append(trigger, popover);

    if (options.pinned === true) {
        pinPopover(popover, trigger);
    }

    root.setTriggerLabel = (label: string): void => {
        triggerLabel.textContent = label;
    };

    root.syncChecked = (value: string): void => {
        checkedValue = value;

        for (const entry of menu.querySelectorAll('[role="menuitem"]')) {
            entry.setAttribute("aria-checked", entry.getAttribute("data-value") === value ? "true" : "false");
        }
    };

    root.setItems = (items): void => {
        currentItems = items;

        if (!materialised) {
            return;
        }

        buildItems(currentItems);
        // Basecoat caches the item list at init; refresh() re-scans for keyboard nav.
        (root as { refresh?: () => void }).refresh?.();
    };

    if (!materialised) {
        const materialise = (): void => {
            if (materialised) {
                return;
            }

            materialised = true;
            root.classList.add("dropdown-menu");
            root.style.removeProperty("position");
            root.style.removeProperty("display");
            root.append(popover);
            buildItems(currentItems);

            if (checkedValue !== undefined) {
                root.syncChecked(checkedValue);
            }

            initBasecoat();
        };

        trigger.addEventListener("focus", materialise);
        trigger.addEventListener("pointerdown", materialise);
        // Preserve Basecoat's closed-root layout without matching its initialiser until the popover exists.
        root.classList.remove("dropdown-menu");
        root.style.position = "relative";
        root.style.display = "inline-flex";
        popover.remove();
    }

    return root;
}
