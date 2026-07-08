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

export type ButtonIntent = "primary" | "quiet" | "outline" | "icon" | "danger";

export type ButtonOptions = {
    id?: string;
    /** Extra classes merged after "btn" (our BEM test-contract classes). */
    className?: string;
    ariaLabel?: string;
    tooltip?: string;
    disabled?: boolean;
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
        <div id="${options.id}-popover" data-popover aria-hidden="true">
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
        list.className = "chrome-segment-joined";
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
            applyIntent(button, "icon", { tooltip: entry.label });
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
    items: { value: string; label: string; disabled?: boolean }[];
    onSelect: (value: string) => void;
};

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

    buildItems(options.items);
    popover.append(menu);
    root.append(trigger, popover);

    root.setTriggerLabel = (label: string): void => {
        triggerLabel.textContent = label;
    };

    root.syncChecked = (value: string): void => {
        for (const entry of menu.querySelectorAll('[role="menuitem"]')) {
            entry.setAttribute("aria-checked", entry.getAttribute("data-value") === value ? "true" : "false");
        }
    };

    root.setItems = (items): void => {
        buildItems(items);
        // Basecoat caches the item list at init; refresh() re-scans for keyboard nav.
        (root as { refresh?: () => void }).refresh?.();
    };

    return root;
}
