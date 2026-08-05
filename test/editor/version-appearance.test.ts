import { beforeEach, describe, expect, it } from "vitest";
import { installVersionAppearance } from "../../src/Verso/Editor/version-appearance.js";

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
    document.body.innerHTML = `
        <span id="verso-theme-trigger">Default</span>
        <div id="verso-theme-menu">
            <button role="menuitem" data-value="studio">Studio</button>
        </div>
        <div id="verso-scheme-group">
            <button data-scheme="light" aria-checked="false">Light</button>
            <button data-scheme="dark" aria-checked="false">Dark</button>
            <button data-scheme="match-system" aria-checked="false">Match system</button>
        </div>`;
}

describe("standalone page appearance controls", (): void => {
    beforeEach((): void => {
        installLocalStorageStub();
        document.documentElement.classList.remove("dark");
        document.documentElement.setAttribute("data-editor-theme", "shadcn");
        mountAppearanceControls();
    });

    it("given a theme menu item, when clicked, then the page applies and stores the theme", (): void => {
        const uninstall = installVersionAppearance();

        document.querySelector<HTMLElement>('[data-value="studio"]')?.click();

        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("studio");
        expect(window.localStorage.getItem("editor-theme")).toBe("studio");
        expect(document.querySelector("#verso-theme-trigger")?.textContent).toBe("Studio");
        uninstall();
    });

    it("given a colour scheme button, when clicked, then the page applies and stores the scheme", (): void => {
        const uninstall = installVersionAppearance();

        document.querySelector<HTMLElement>('[data-scheme="dark"]')?.click();

        expect(document.documentElement.classList.contains("dark")).toBe(true);
        expect(window.localStorage.getItem("editor-color-scheme")).toBe("dark");
        expect(document.querySelector('[data-scheme="dark"]')?.getAttribute("aria-checked")).toBe("true");
        expect(document.querySelector('[data-scheme="light"]')?.getAttribute("aria-checked")).toBe("false");
        uninstall();
    });

    it("given stored appearance preferences, when installed, then the controls reflect them", (): void => {
        window.localStorage.setItem("editor-theme", "studio");
        window.localStorage.setItem("editor-color-scheme", "dark");

        const uninstall = installVersionAppearance();

        expect(document.querySelector("#verso-theme-trigger")?.textContent).toBe("Studio");
        expect(document.querySelector('[data-scheme="dark"]')?.getAttribute("aria-checked")).toBe("true");
        uninstall();
    });
});
