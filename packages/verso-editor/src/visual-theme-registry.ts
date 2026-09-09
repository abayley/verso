/** Browser capabilities that a visual theme can activate. */
interface VisualThemeCapabilities {
    readonly contextualEditingSurfaces: boolean;
}

/** The resolved visual theme state used by browser callers. */
export interface VisualThemeState {
    readonly id: string;
    readonly label: string;
    readonly capabilities: VisualThemeCapabilities;
}

/** One visual theme choice shown in browser controls. */
export interface VisualThemeChoice {
    readonly id: string;
    readonly label: string;
}

/** Theme ids that disagree between the browser registry and handwritten CSS. */
export interface VisualThemeCssCheck {
    readonly missingThemeIds: readonly string[];
    readonly unregisteredThemeIds: readonly string[];
}

interface VisualThemeDescriptor extends VisualThemeState {
    readonly default: boolean;
    readonly activateDocument?: () => void;
}

const visualThemeStorageKey = "editor-theme";

const visualThemes: readonly VisualThemeDescriptor[] = [
    {
        id: "shadcn",
        label: "Default",
        default: true,
        capabilities: { contextualEditingSurfaces: false },
    },
    {
        id: "studio",
        label: "Studio",
        default: false,
        capabilities: { contextualEditingSurfaces: true },
    },
    {
        id: "moebius",
        label: "Moebius",
        default: false,
        capabilities: { contextualEditingSurfaces: false },
        activateDocument: installMoebiusFilterDefs,
    },
];

/** Installs the Moebius theme's live SVG filters once. */
function installMoebiusFilterDefs(): void {
    if (document.getElementById("moebius-filter-defs")) {
        return;
    }

    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.id = "moebius-filter-defs";
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("width", "0");
    svg.setAttribute("height", "0");
    svg.style.position = "absolute";
    svg.innerHTML = [
        '<filter id="moebius-wobble-a" x="-10%" y="-10%" width="120%" height="120%">',
        '<feTurbulence type="fractalNoise" baseFrequency="0.012 0.018" numOctaves="2" seed="7" result="n"/>',
        '<feDisplacementMap in="SourceGraphic" in2="n" scale="2.5" xChannelSelector="R" yChannelSelector="G"/>',
        "</filter>",
        '<filter id="moebius-wobble-b" x="-10%" y="-10%" width="120%" height="120%">',
        '<feTurbulence type="fractalNoise" baseFrequency="0.014 0.02" numOctaves="2" seed="13" result="n"/>',
        '<feDisplacementMap in="SourceGraphic" in2="n" scale="2.5" xChannelSelector="R" yChannelSelector="G"/>',
        "</filter>",
    ].join("");
    document.body.append(svg);
}

/** Returns the registry's one explicit default and rejects an invalid authored registry. */
function defaultVisualTheme(): VisualThemeDescriptor {
    const defaults = visualThemes.filter((theme) => theme.default);
    if (defaults.length !== 1 || defaults[0] === undefined) {
        throw new Error("The visual theme registry must declare exactly one default");
    }
    return defaults[0];
}

/** Resolves an arbitrary id through the authored registry. */
function resolveVisualThemeId(id: string | null): VisualThemeDescriptor {
    return visualThemes.find((theme) => theme.id === id) ?? defaultVisualTheme();
}

/** Hides registry-only fields from browser callers. */
function publicVisualTheme(theme: VisualThemeDescriptor): VisualThemeState {
    return { id: theme.id, label: theme.label, capabilities: theme.capabilities };
}

/** Applies one validated descriptor to the root without running deferred document activation. */
function applyVisualTheme(theme: VisualThemeDescriptor): VisualThemeState {
    document.documentElement.setAttribute("data-editor-theme", theme.id);
    return publicVisualTheme(theme);
}

/** Applies and activates one validated descriptor after the document body exists. */
function activateVisualTheme(theme: VisualThemeDescriptor): VisualThemeState {
    const state = applyVisualTheme(theme);
    theme.activateDocument?.();
    return state;
}

/** Reads the stored visual theme id without exposing storage failures to callers. */
function storedVisualThemeId(): string | null {
    try {
        return window.localStorage.getItem(visualThemeStorageKey);
    } catch {
        return null;
    }
}

/** Resolves the stored visual theme id to the registry default when it is absent or unknown. */
export function resolveStoredVisualTheme(): VisualThemeState {
    return publicVisualTheme(resolveVisualThemeId(storedVisualThemeId()));
}

/** Lists the visual theme choices in their browser display order. */
export function listVisualThemes(): readonly VisualThemeChoice[] {
    return visualThemes.map(({ id, label }) => ({ id, label }));
}

/** Compares theme selectors in a stylesheet with the registry's non-default themes. */
export function checkVisualThemeCss(css: string): VisualThemeCssCheck {
    const selectorThemeIds = new Set<string>();
    for (const match of css.matchAll(/:root\[data-editor-theme=["']([^"']+)["']\]/g)) {
        const id = match[1];
        if (id !== undefined) {
            selectorThemeIds.add(id);
        }
    }

    const registeredThemeIds = new Set(visualThemes.map((theme) => theme.id));
    const missingThemeIds = visualThemes
        .filter((theme) => !theme.default && !selectorThemeIds.has(theme.id))
        .map((theme) => theme.id);
    const unregisteredThemeIds = Array.from(selectorThemeIds).filter((id) => !registeredThemeIds.has(id));
    return { missingThemeIds, unregisteredThemeIds };
}

/** Applies the resolved stored visual theme to the document root before first paint. */
export function applyStoredVisualTheme(): VisualThemeState {
    return applyVisualTheme(resolveVisualThemeId(storedVisualThemeId()));
}

/** Resolves and activates the stored theme once the deferred browser bundle has loaded. */
export function initialiseVisualTheme(): VisualThemeState {
    return activateVisualTheme(resolveVisualThemeId(storedVisualThemeId()));
}

/** Selects, applies, and stores a visual theme through the authored registry. */
export function selectVisualTheme(id: string): VisualThemeState {
    const theme = resolveVisualThemeId(id);
    const state = activateVisualTheme(theme);
    try {
        window.localStorage.setItem(visualThemeStorageKey, theme.id);
    } catch {
        // Persistence is optional. The selected theme remains active for this page.
    }
    return state;
}
