import { beforeEach, describe, expect, it } from "vitest";
import { installVersionAppearance } from "../src/version-appearance.js";

/** Installs a fresh in-memory localStorage. */
function installLocalStorageStub(): void {
    const store = new Map<string, string>();
    const stub: Storage = {
        get length(): number {
            return store.size;
        },
        clear: (): void => store.clear(),
        getItem: (key: string): string | null => store.get(key) ?? null,
        key: (index: number): string | null => Array.from(store.keys())[index] ?? null,
        removeItem: (key: string): void => {
            store.delete(key);
        },
        setItem: (key: string, value: string): void => {
            store.set(key, value);
        },
    };
    Object.defineProperty(window, "localStorage", { configurable: true, value: stub });
}

/** Mounts the appearance controls shared by the standalone pages. */
function mountAppearanceControls(): void {
    document.body.innerHTML = '<div id="verso-appearance-controls"></div>';
}

describe("standalone page appearance controls", (): void => {
    beforeEach((): void => {
        installLocalStorageStub();
        document.documentElement.classList.remove("dark");
        document.documentElement.setAttribute("data-editor-theme", "shadcn");
        mountAppearanceControls();
    });

    it("given an empty appearance host, when installed, then registry controls are rendered", (): void => {
        document.body.innerHTML = '<div id="verso-appearance-controls"></div>';

        const uninstall = installVersionAppearance();

        expect({
            themes: Array.from(
                document.querySelectorAll<HTMLElement>("#verso-theme-menu [data-value]"),
                (item) => item.dataset["value"],
            ),
            schemeToggles: document.querySelectorAll("#verso-scheme-toggle").length,
        }).toEqual({
            themes: ["shadcn", "studio", "moebius"],
            schemeToggles: 1,
        });
        uninstall();
    });

    it("given a theme menu item, when clicked, then the page applies and stores the theme", (): void => {
        const uninstall = installVersionAppearance();

        document.querySelector<HTMLElement>('[data-value="studio"]')?.click();

        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("studio");
        expect(window.localStorage.getItem("editor-theme")).toBe("studio");
        expect(document.querySelector("#verso-theme-menu-trigger span")?.textContent).toBe("Studio");
        uninstall();
    });

    it("given the light scheme, when the toggle is pressed, then the page applies and stores dark", (): void => {
        window.localStorage.setItem("editor-color-scheme", "light");
        const uninstall = installVersionAppearance();

        document.querySelector<HTMLElement>("#verso-scheme-toggle")?.click();

        expect(document.documentElement.classList.contains("dark")).toBe(true);
        expect(window.localStorage.getItem("editor-color-scheme")).toBe("dark");
        uninstall();
    });

    it("given the dark scheme, when the toggle is installed, then it offers the light theme with a sun", (): void => {
        window.localStorage.setItem("editor-theme", "studio");
        window.localStorage.setItem("editor-color-scheme", "dark");

        const uninstall = installVersionAppearance();

        const toggle = document.querySelector("#verso-scheme-toggle");
        expect(document.querySelector("#verso-theme-menu-trigger span")?.textContent).toBe("Studio");
        expect(toggle?.getAttribute("aria-label")).toBe("Switch to light theme");
        expect(toggle?.querySelector("use")?.getAttribute("href")).toBe("/static/editor/icons.svg#i-sun");
        uninstall();
    });

    it("given the light scheme, when the toggle is installed, then it offers the dark theme with a moon", (): void => {
        window.localStorage.setItem("editor-color-scheme", "light");

        const uninstall = installVersionAppearance();

        const toggle = document.querySelector("#verso-scheme-toggle");
        expect(toggle?.getAttribute("aria-label")).toBe("Switch to dark theme");
        expect(toggle?.querySelector("use")?.getAttribute("href")).toBe("/static/editor/icons.svg#i-moon");
        uninstall();
    });
});
