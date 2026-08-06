import { applyStoredVisualTheme, type VisualThemeState } from "./visual-theme-registry.js";

/** The browser colour-scheme preference values. */
export type ColourScheme = "light" | "dark" | "match-system";

/** The appearance state resolved by the synchronous bootstrap. */
export interface AppearanceState {
    readonly visualTheme: VisualThemeState;
    readonly colourScheme: ColourScheme;
}

const colourSchemeStorageKey = "editor-color-scheme";

/** Checks a stored value before it reaches the document root. */
function isColourScheme(value: string | null): value is ColourScheme {
    return value === "light" || value === "dark" || value === "match-system";
}

/** Reads the stored colour scheme without exposing storage failures to callers. */
export function resolveStoredColourScheme(): ColourScheme {
    try {
        const stored = window.localStorage.getItem(colourSchemeStorageKey);
        return isColourScheme(stored) ? stored : "match-system";
    } catch {
        return "match-system";
    }
}

/** Applies the current colour scheme to the document root. */
export function applyColourScheme(scheme: ColourScheme): void {
    const systemDark =
        typeof window.matchMedia === "function" && window.matchMedia("(prefers-color-scheme: dark)").matches;
    const dark = scheme === "dark" || (scheme === "match-system" && systemDark);
    document.documentElement.classList.toggle("dark", dark);
}

/** Selects, applies, and stores a colour scheme for the current browser. */
export function selectColourScheme(value: string): ColourScheme {
    const scheme = isColourScheme(value) ? value : "match-system";
    applyColourScheme(scheme);
    try {
        window.localStorage.setItem(colourSchemeStorageKey, scheme);
    } catch {
        // Persistence is optional. The selected scheme remains active for this page.
    }
    return scheme;
}

/** Applies stored visual-theme and colour-scheme preferences before first paint. */
export function applyStoredAppearance(): AppearanceState {
    document.documentElement.classList.add("js");
    const visualTheme = applyStoredVisualTheme();
    const colourScheme = resolveStoredColourScheme();
    applyColourScheme(colourScheme);
    return { visualTheme, colourScheme };
}
