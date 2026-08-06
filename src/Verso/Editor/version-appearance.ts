import { applyColourScheme, type ColourScheme, resolveStoredColourScheme, selectColourScheme } from "./appearance.js";
import {
    type ChromeDropdownElement,
    type ChromeSegmentElement,
    chromeDropdownEl,
    chromeSegmentEl,
    initBasecoat,
} from "./chrome.js";
import {
    initialiseVisualTheme,
    listVisualThemes,
    selectVisualTheme,
    type VisualThemeState,
} from "./visual-theme-registry.js";

const colourSchemeChoices: readonly { value: ColourScheme; label: string; icon: string }[] = [
    { value: "light", label: "Light", icon: "sun" },
    { value: "dark", label: "Dark", icon: "moon" },
    { value: "match-system", label: "Match system", icon: "monitor" },
];

/** Installs browser-rendered appearance controls on standalone pages. */
export function installVersionAppearance(): () => void {
    const host = document.querySelector<HTMLElement>("#verso-appearance-controls");
    if (!host) {
        return (): void => undefined;
    }

    const visualTheme = initialiseVisualTheme();
    const themeDropdown = createThemeDropdown(visualTheme);
    const colourScheme = resolveStoredColourScheme();
    applyColourScheme(colourScheme);
    const schemeGroup = createSchemeGroup(colourScheme);
    host.replaceChildren(themeDropdown, schemeGroup);
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

/** Creates the browser-owned colour scheme control. */
function createSchemeGroup(initialScheme: ColourScheme): ChromeSegmentElement {
    const group = chromeSegmentEl({
        className: "markdown-editor__theme-group",
        ariaLabel: "Editor colour theme",
        joined: true,
        entries: colourSchemeChoices.map((scheme) => ({ ...scheme, iconOnly: true })),
    });
    group.id = "verso-scheme-group";
    group.sync(initialScheme);
    group.addEventListener("change", (): void => {
        group.sync(selectColourScheme(group.value));
    });
    return group;
}
