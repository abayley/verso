import { beforeEach, describe, expect, it } from "vitest";
import {
    applyStoredVisualTheme,
    checkVisualThemeCss,
    listVisualThemes,
    resolveStoredVisualTheme,
    selectVisualTheme,
} from "../src/visual-theme-registry.js";

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

describe("visual theme registry", (): void => {
    beforeEach((): void => {
        installLocalStorageStub();
        document.documentElement.removeAttribute("data-editor-theme");
        document.getElementById("moebius-filter-defs")?.remove();
    });

    it("given an unknown stored id, when resolved, then the explicit default and its capabilities are returned", (): void => {
        window.localStorage.setItem("editor-theme", "unknown-theme");

        expect(resolveStoredVisualTheme()).toEqual({
            id: "shadcn",
            label: "Default",
            capabilities: { contextualEditingSurfaces: false },
        });
    });

    it("given unavailable storage, when resolved, then the default is returned without throwing", (): void => {
        Object.defineProperty(window, "localStorage", {
            configurable: true,
            get: (): never => {
                throw new Error("storage unavailable");
            },
        });

        expect(resolveStoredVisualTheme().id).toBe("shadcn");
    });

    it("given a registered stored id, when resolved, then its label and capability state are returned", (): void => {
        window.localStorage.setItem("editor-theme", "studio");

        expect(resolveStoredVisualTheme()).toEqual({
            id: "studio",
            label: "Studio",
            capabilities: { contextualEditingSurfaces: true },
        });
    });

    it("given a known stored theme, when the early bootstrap runs, then the root theme is applied", (): void => {
        window.localStorage.setItem("editor-theme", "studio");

        applyStoredVisualTheme();

        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("studio");
    });

    it("given a registered theme, when selected, then root, storage, and capability state agree", (): void => {
        const selected = selectVisualTheme("studio");

        expect({
            selected,
            root: document.documentElement.getAttribute("data-editor-theme"),
            stored: window.localStorage.getItem("editor-theme"),
        }).toEqual({
            selected: {
                id: "studio",
                label: "Studio",
                capabilities: { contextualEditingSurfaces: true },
            },
            root: "studio",
            stored: "studio",
        });
    });

    it("given the authored registry, when choices are listed, then every browser theme is returned in display order", (): void => {
        expect(listVisualThemes()).toEqual([
            { id: "shadcn", label: "Default" },
            { id: "studio", label: "Studio" },
            { id: "moebius", label: "Moebius" },
        ]);
    });

    it("given theme CSS, when checked against the registry, then missing and unregistered selectors are both reported", (): void => {
        const matchingCss = `
            :root[data-editor-theme="studio"] .editor { color: red; }
            :root[data-editor-theme='moebius'] { color: blue; }
        `;
        const mismatchingCss = `
            :root[data-editor-theme="studio"] .editor { color: red; }
            :root[data-editor-theme="ghost"] { color: green; }
        `;

        expect(checkVisualThemeCss(matchingCss)).toEqual({ missingThemeIds: [], unregisteredThemeIds: [] });
        expect(checkVisualThemeCss(mismatchingCss)).toEqual({
            missingThemeIds: ["moebius"],
            unregisteredThemeIds: ["ghost"],
        });
    });

    it("given a theme with document activation, when selected twice, then its assets are installed once", (): void => {
        selectVisualTheme("moebius");
        selectVisualTheme("moebius");

        const defs = document.querySelectorAll("#moebius-filter-defs");
        expect({
            count: defs.length,
            filters: defs[0]?.querySelectorAll("filter").length,
        }).toEqual({ count: 1, filters: 2 });
    });
});
