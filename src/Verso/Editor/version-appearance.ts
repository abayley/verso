const themeLabels: Readonly<Record<string, string>> = {
    shadcn: "Default",
    studio: "Studio",
    moebius: "Moebius",
};

/** Installs the appearance controls shared by standalone pages. */
export function installVersionAppearance(): () => void {
    const storedTheme = window.localStorage.getItem("editor-theme");
    const currentTheme = storedTheme ?? document.documentElement.getAttribute("data-editor-theme");
    const currentThemeLabel = currentTheme ? themeLabels[currentTheme] : undefined;
    const trigger = document.querySelector<HTMLElement>("#verso-theme-trigger");
    if (trigger && currentThemeLabel) {
        trigger.textContent = currentThemeLabel;
    }

    const storedScheme = window.localStorage.getItem("editor-color-scheme");
    const currentScheme = isColourScheme(storedScheme) ? storedScheme : "match-system";
    applyScheme(currentScheme);
    reflectScheme(currentScheme);

    const onClick = (event: Event): void => {
        const target = event.target instanceof Element ? event.target : null;
        const item = target?.closest<HTMLElement>('#verso-theme-menu [role="menuitem"][data-value]');
        const value = item?.dataset["value"];
        const label = value ? themeLabels[value] : undefined;
        if (value && label) {
            window.localStorage.setItem("editor-theme", value);
            document.documentElement.setAttribute("data-editor-theme", value);
            const themeTrigger = document.querySelector<HTMLElement>("#verso-theme-trigger");
            if (themeTrigger) {
                themeTrigger.textContent = label;
            }
        }

        const schemeButton = target?.closest<HTMLElement>("#verso-scheme-group [data-scheme]");
        const scheme = schemeButton?.dataset["scheme"];
        if (scheme === "light" || scheme === "dark" || scheme === "match-system") {
            window.localStorage.setItem("editor-color-scheme", scheme);
            applyScheme(scheme);
            reflectScheme(scheme);
        }
    };

    document.addEventListener("click", onClick);
    return (): void => document.removeEventListener("click", onClick);
}

/** Checks a stored value before it reaches the colour scheme controls. */
function isColourScheme(value: string | null): value is "light" | "dark" | "match-system" {
    return value === "light" || value === "dark" || value === "match-system";
}

/** Applies an explicit scheme, or the operating system preference for match-system. */
function applyScheme(scheme: "light" | "dark" | "match-system"): void {
    const systemDark = window.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;
    document.documentElement.classList.toggle("dark", scheme === "dark" || (scheme === "match-system" && systemDark));
}

/** Reflects the selected scheme on the standalone page's radio buttons. */
function reflectScheme(scheme: "light" | "dark" | "match-system"): void {
    for (const button of document.querySelectorAll<HTMLElement>("#verso-scheme-group [data-scheme]")) {
        button.setAttribute("aria-checked", String(button.dataset["scheme"] === scheme));
    }
}
