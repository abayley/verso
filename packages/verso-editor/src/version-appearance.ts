import { applyColourScheme, effectiveColourScheme } from "./appearance.js";
import { type ChromeDropdownElement, chromeDropdownEl, initBasecoat } from "./chrome.js";
import { createColourSchemeToggle } from "./colour-scheme-toggle.js";
import {
    initialiseVisualTheme,
    listVisualThemes,
    selectVisualTheme,
    type VisualThemeState,
} from "./visual-theme-registry.js";

/** Installs browser-rendered appearance controls on standalone pages. */
export function installVersionAppearance(): () => void {
    const host = document.querySelector<HTMLElement>("#verso-appearance-controls");
    if (!host) {
        return (): void => undefined;
    }

    const visualTheme = initialiseVisualTheme();
    const themeDropdown = createThemeDropdown(visualTheme);
    applyColourScheme(effectiveColourScheme());
    const schemeToggle = createColourSchemeToggle("markdown-editor__theme-toggle");
    schemeToggle.id = "verso-scheme-toggle";
    host.replaceChildren(themeDropdown, schemeToggle);
    initBasecoat();

    return (): void => host.replaceChildren();
}

/** Creates the registry-backed visual theme control. */
function createThemeDropdown(initialTheme: VisualThemeState): ChromeDropdownElement {
    const dropdown = chromeDropdownEl({
        id: "verso-theme-menu",
        className: "markdown-editor__theme-dropdown",
        intent: "quiet",
        triggerLabel: initialTheme.label,
        ariaLabel: "Visual theme",
        items: listVisualThemes().map((theme) => ({ value: theme.id, label: theme.label })),
        onSelect: (value: string): void => {
            const selected = selectVisualTheme(value);
            dropdown.setTriggerLabel(selected.label);
            dropdown.syncChecked(selected.id);
        },
    });
    dropdown.syncChecked(initialTheme.id);
    return dropdown;
}
