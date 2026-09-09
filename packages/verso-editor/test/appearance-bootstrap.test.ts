import { beforeEach, describe, expect, it } from "vitest";
import { applyStoredAppearance, effectiveColourScheme, toggleColourScheme } from "../src/appearance.js";

/** Pins the browser's reported colour preference for a test. */
function setSystemDark(dark: boolean): void {
    Object.defineProperty(window, "matchMedia", {
        configurable: true,
        value: (): Pick<MediaQueryList, "matches"> => ({ matches: dark }),
    });
}

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

    it("given no stored scheme and a dark browser preference, when the bootstrap runs, then dark is applied", (): void => {
        setSystemDark(true);

        applyStoredAppearance();

        expect(document.documentElement.classList.contains("dark")).toBe(true);
    });

    it("given no stored scheme and a light browser preference, when the bootstrap runs, then dark is not applied", (): void => {
        setSystemDark(false);

        applyStoredAppearance();

        expect(document.documentElement.classList.contains("dark")).toBe(false);
    });

    // The selector used to have a third "match-system" state, which existing browsers still
    // have in storage. It means the same thing as storing nothing: follow the system.
    it("given the retired match-system value stored and a dark browser preference, when the bootstrap runs, then dark is applied", (): void => {
        window.localStorage.setItem("editor-color-scheme", "match-system");
        setSystemDark(true);

        applyStoredAppearance();

        expect(document.documentElement.classList.contains("dark")).toBe(true);
    });

    it("given a stored light scheme and a dark browser preference, when the scheme is resolved, then the stored one wins", (): void => {
        window.localStorage.setItem("editor-color-scheme", "light");
        setSystemDark(true);

        expect(effectiveColourScheme()).toBe("light");
    });

    it("given an unreadable stored value and a dark browser preference, when the scheme is resolved, then the system setting is used", (): void => {
        window.localStorage.setItem("editor-color-scheme", "chartreuse");
        setSystemDark(true);

        expect(effectiveColourScheme()).toBe("dark");
    });
});

describe("colour scheme toggle", (): void => {
    beforeEach((): void => {
        installLocalStorageStub();
        document.documentElement.classList.remove("dark");
    });

    it("given the light scheme in effect, when toggled, then dark is applied and stored", (): void => {
        setSystemDark(false);
        applyStoredAppearance();

        expect(toggleColourScheme()).toBe("dark");
        expect(document.documentElement.classList.contains("dark")).toBe(true);
        expect(window.localStorage.getItem("editor-color-scheme")).toBe("dark");
    });

    it("given the dark scheme in effect, when toggled, then light is applied and stored", (): void => {
        window.localStorage.setItem("editor-color-scheme", "dark");
        applyStoredAppearance();

        expect(toggleColourScheme()).toBe("light");
        expect(document.documentElement.classList.contains("dark")).toBe(false);
        expect(window.localStorage.getItem("editor-color-scheme")).toBe("light");
    });

    // Following the system is the starting state, not a state the button can return to: the
    // first press pins a preference, which is what the two-state control means.
    it("given no stored scheme and a dark browser preference, when toggled, then light is applied and stored", (): void => {
        setSystemDark(true);
        applyStoredAppearance();

        expect(toggleColourScheme()).toBe("light");
        expect(window.localStorage.getItem("editor-color-scheme")).toBe("light");
    });

    it("given storage that refuses writes, when toggled, then the scheme still applies", (): void => {
        setSystemDark(false);
        applyStoredAppearance();
        Object.defineProperty(window, "localStorage", {
            configurable: true,
            get: (): Storage => {
                throw new Error("storage disabled");
            },
        });

        expect(toggleColourScheme()).toBe("dark");
        expect(document.documentElement.classList.contains("dark")).toBe(true);
    });
});
