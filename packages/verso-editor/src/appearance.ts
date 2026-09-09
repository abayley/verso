import { applyStoredVisualTheme, type VisualThemeState } from "./visual-theme-registry.js";

/**
 * The colour schemes the document can be in.
 *
 * There is no "match-system" member. Following the system is the absence of a stored
 * preference rather than a scheme of its own, which is what lets the selector be a single
 * two-state button: it starts wherever the system is, and the first press pins a choice.
 */
export type ColourScheme = "light" | "dark";

/** The appearance state resolved by the synchronous bootstrap. */
export interface AppearanceState {
    readonly visualTheme: VisualThemeState;
    readonly colourScheme: ColourScheme;
}

const colourSchemeStorageKey = "editor-color-scheme";

/** Checks a stored value before it reaches the document root. */
function isColourScheme(value: string | null): value is ColourScheme {
    return value === "light" || value === "dark";
}

/** Whether the browser reports a dark colour preference. */
function systemPrefersDark(): boolean {
    return typeof window.matchMedia === "function" && window.matchMedia("(prefers-color-scheme: dark)").matches;
}

/**
 * The stored preference, or null when there is none and the system decides.
 *
 * A value that is neither "light" nor "dark" reads as no preference. That covers the
 * retired "match-system" value, which browsers that used the three-state selector still
 * have in storage and which meant exactly this.
 */
export function storedColourScheme(): ColourScheme | null {
    try {
        const stored = window.localStorage.getItem(colourSchemeStorageKey);
        return isColourScheme(stored) ? stored : null;
    } catch {
        return null;
    }
}

/** The scheme in force: the stored preference if there is one, else the system's. */
export function effectiveColourScheme(): ColourScheme {
    return storedColourScheme() ?? (systemPrefersDark() ? "dark" : "light");
}

/** Applies a colour scheme to the document root. */
export function applyColourScheme(scheme: ColourScheme): void {
    document.documentElement.classList.toggle("dark", scheme === "dark");
}

/** Applies and stores a colour scheme for this browser. */
function selectColourScheme(scheme: ColourScheme): ColourScheme {
    applyColourScheme(scheme);
    try {
        window.localStorage.setItem(colourSchemeStorageKey, scheme);
    } catch {
        // Persistence is optional. The selected scheme remains active for this page.
    }
    return scheme;
}

/** Switches to the other scheme, pinning it as this browser's preference. */
export function toggleColourScheme(): ColourScheme {
    return selectColourScheme(effectiveColourScheme() === "dark" ? "light" : "dark");
}

/** Applies stored visual-theme and colour-scheme preferences before first paint. */
export function applyStoredAppearance(): AppearanceState {
    document.documentElement.classList.add("js");
    const visualTheme = applyStoredVisualTheme();
    const colourScheme = effectiveColourScheme();
    applyColourScheme(colourScheme);
    return { visualTheme, colourScheme };
}
