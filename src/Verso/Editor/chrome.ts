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
 * window.basecoat.initAll() from that element's updated() hook.
 */

import { html, type TemplateResult } from "lit";
import { ifDefined } from "lit/directives/if-defined.js";

export type ButtonIntent = "primary" | "quiet" | "outline" | "icon";

export type ButtonOptions = {
    id?: string;
    ariaLabel?: string;
    tooltip?: string;
    onClick?: (event: Event) => void;
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
    }
}

/** A non-submitting chrome button. */
export function chromeButton(
    intent: ButtonIntent,
    content: TemplateResult | string,
    options: ButtonOptions,
): TemplateResult {
    const attrs = intentAttrs(intent);

    return html`<button
        type="button"
        class="btn"
        id=${ifDefined(options.id)}
        data-variant=${ifDefined(attrs.variant)}
        data-size=${attrs.size}
        aria-label=${ifDefined(options.ariaLabel)}
        data-tooltip=${ifDefined(options.tooltip)}
        @click=${options.onClick}
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

type DropdownItem = { value: string; label: string };

export type DropdownOptions = {
    id: string;
    intent: ButtonIntent;
    trigger: TemplateResult | string;
    items: DropdownItem[];
    onSelect: (value: string) => void;
};

/**
 * A Basecoat dropdown menu with the full id/ARIA wiring derived from the
 * base id. Selection is reported through onSelect with the item's value.
 */
export function chromeDropdown(options: DropdownOptions): TemplateResult {
    const attrs = intentAttrs(options.intent);

    return html`<div class="dropdown-menu" id=${options.id}>
        <button
            type="button"
            class="btn"
            id="${options.id}-trigger"
            data-variant=${ifDefined(attrs.variant)}
            data-size=${attrs.size}
            aria-haspopup="menu"
            aria-controls="${options.id}-menu"
            aria-expanded="false"
        >${options.trigger}</button>
        <div id="${options.id}-popover" data-popover aria-hidden="true">
            <div role="menu" id="${options.id}-menu" aria-labelledby="${options.id}-trigger">
                ${options.items.map(
                    (item) =>
                        html`<button
                            type="button"
                            role="menuitem"
                            data-value=${item.value}
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
    entries: TabEntry[];
    onSelect: (value: string) => void;
};

/** A Basecoat line-variant tab strip; clicks report the entry's value. */
export function chromeTabs(options: TabsOptions): TemplateResult {
    return html`<div class="tabs" id=${options.id}>
        <nav role="tablist" aria-orientation="horizontal" data-variant="line">
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
