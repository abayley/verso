import { beforeEach, describe, expect, it } from "vitest";
import { applyStoredAppearance } from "../../src/Verso/Editor/appearance.js";

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

describe("appearance bootstrap", (): void => {
    beforeEach((): void => {
        installLocalStorageStub();
        document.documentElement.classList.remove("dark");
    });

    it("given a stored dark scheme, when the bootstrap runs, then the dark root class is applied", (): void => {
        window.localStorage.setItem("editor-color-scheme", "dark");

        applyStoredAppearance();

        expect(document.documentElement.classList.contains("dark")).toBe(true);
    });

    it("given a stored light scheme, when the bootstrap runs, then a dark root class is removed", (): void => {
        document.documentElement.classList.add("dark");
        window.localStorage.setItem("editor-color-scheme", "light");

        applyStoredAppearance();

        expect(document.documentElement.classList.contains("dark")).toBe(false);
    });

    it("given match-system and a dark browser preference, when the bootstrap runs, then dark is applied", (): void => {
        window.localStorage.setItem("editor-color-scheme", "match-system");
        Object.defineProperty(window, "matchMedia", {
            configurable: true,
            value: (): Pick<MediaQueryList, "matches"> => ({ matches: true }),
        });

        applyStoredAppearance();

        expect(document.documentElement.classList.contains("dark")).toBe(true);
    });
});
