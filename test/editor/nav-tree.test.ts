import { beforeEach, describe, expect, it } from "vitest";
import {
    activeNodePath,
    type NavTreeOptions,
    NavTreePanel,
    parseTreeChildren,
    parseTreeSpine,
} from "../../src/Verso/Editor/nav-tree.js";

/** Builds a nav panel over a small fixed tree (root -> Engineering[Runbook], Guide), open at Runbook. */
function mountNav(overrides: Record<string, unknown> = {}): { panel: HTMLElement; navigateCalls: string[] } {
    const navigateCalls: string[] = [];
    const eng = { hasChildren: true, kind: "section", name: "Engineering", path: "engineering" };
    const guide = { hasChildren: true, kind: "section", name: "Guide", path: "guide" };
    const runbook = { hasChildren: false, kind: "page", name: "Runbook", path: "engineering/runbook.md" };
    const options = {
        documentPath: "engineering/runbook.md",
        spine: [
            { children: [eng, guide], path: "" },
            { children: [runbook], path: "engineering" },
        ],
        fetchChildren: async (): Promise<unknown[]> => [],
        navigate: (path: string): void => {
            navigateCalls.push(path);
        },
        registerTooltip: (): void => {},
        notify: (): void => {},
        createNode: async (): Promise<null> => null,
        deleteNode: async (): Promise<unknown> => ({}),
        moveNode: async (): Promise<unknown> => ({}),
        undo: async (): Promise<unknown> => ({}),
        listMoves: async (): Promise<unknown[]> => [],
        listTrash: async (): Promise<unknown[]> => [],
        restore: async (): Promise<unknown> => ({}),
        ...overrides,
    } as unknown as NavTreeOptions;
    const tree = new NavTreePanel(options);
    const panel = tree.element();
    document.body.append(panel);

    return { navigateCalls, panel };
}

/** The section/page labels the panel is rendering. */
function navLabel(panel: HTMLElement, text: string): HTMLElement {
    const label = [...panel.querySelectorAll(".markdown-editor__nav-label")].find(
        (element): boolean => element.textContent === text,
    );

    if (!(label instanceof HTMLElement)) {
        throw new Error(`Expected a nav label: ${text}`);
    }

    return label;
}

/** The persisted expanded-folder set (`editor-nav-expanded`). */
function expandedPaths(): string[] {
    const raw = window.localStorage.getItem("editor-nav-expanded");

    return raw ? (JSON.parse(raw) as string[]) : [];
}

/** Installs a fresh in-memory localStorage (happy-dom does not provide one). */
function installLocalStorageStub(): void {
    const store = new Map<string, string>();
    const stub: Storage = {
        get length(): number {
            return store.size;
        },
        clear(): void {
            store.clear();
        },
        getItem(key: string): string | null {
            return store.has(key) ? (store.get(key) as string) : null;
        },
        key(index: number): string | null {
            return Array.from(store.keys())[index] ?? null;
        },
        removeItem(key: string): void {
            store.delete(key);
        },
        setItem(key: string, value: string): void {
            store.set(key, value);
        },
    };
    Object.defineProperty(window, "localStorage", { configurable: true, value: stub });
}

describe("NavTreePanel navigation (RFC-0026)", () => {
    beforeEach((): void => {
        installLocalStorageStub();
        document.body.replaceChildren();
    });

    it("given a section label click, when opening, then the section expands and the browser navigates", () => {
        const { panel, navigateCalls } = mountNav();

        navLabel(panel, "Guide").dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(navigateCalls).toHaveLength(1);
        expect(expandedPaths()).toContain("guide");
    });

    it("given other branches expanded, when Collapse all is clicked, then only the open page's spine stays", () => {
        window.localStorage.setItem("editor-nav-expanded", JSON.stringify(["guide"]));
        const { panel } = mountNav();

        const collapseAll = panel.querySelector(".markdown-editor__nav-collapse-all");
        collapseAll?.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        const expanded = expandedPaths();
        expect(expanded).toContain("engineering");
        expect(expanded).not.toContain("guide");
    });

    it("given an unreachable server, when the undo dropdown opens, then it shows the error item", async () => {
        const { panel } = mountNav({ listMoves: async (): Promise<null> => null });

        const trigger = panel.querySelector("#nav-undo-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        await new Promise((resolve) => setTimeout(resolve));

        const labels = [...panel.querySelectorAll('#nav-undo-menu [role="menuitem"]')].map(
            (item): string => item.textContent?.trim() ?? "",
        );
        expect(labels).toContain("Couldn’t reach the server.");
    });

    it("given an unreachable server, when the trash dropdown opens, then it shows the error item (view-all stays)", async () => {
        const { panel } = mountNav({ listTrash: async (): Promise<null> => null });

        const trigger = panel.querySelector("#nav-trash-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        await new Promise((resolve) => setTimeout(resolve));

        const labels = [...panel.querySelectorAll('#nav-trash-menu [role="menuitem"]')].map(
            (item): string => item.textContent?.trim() ?? "",
        );
        expect(labels).toContain("Couldn’t reach the server.");
        expect(labels).toContain("View all in trash…");
    });

    it("given logged moves, when the undo dropdown opens, then a view-all item linking the undo page is last", async () => {
        const { panel } = mountNav({
            listMoves: async (): Promise<unknown[]> => [{ seq: 0, from: "a", to: "b/a" }],
        });

        const trigger = panel.querySelector("#nav-undo-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        await new Promise((resolve) => setTimeout(resolve));

        const labels = [...panel.querySelectorAll('#nav-undo-menu [role="menuitem"]')].map(
            (item): string => item.textContent?.trim() ?? "",
        );
        expect(labels[labels.length - 1]).toBe("View all moves…");
        expect(labels).toContain("a → b/a");
    });
});

describe("parseTreeChildren", () => {
    it("parses well-formed nodes, defaulting hasChildren", () => {
        const json = JSON.stringify([
            { name: "Alpha", path: "alpha", kind: "section", hasChildren: true },
            { name: "Home", path: "home.md", kind: "page", hasChildren: false },
        ]);
        expect(parseTreeChildren(json)).toEqual([
            { name: "Alpha", path: "alpha", kind: "section", hasChildren: true },
            { name: "Home", path: "home.md", kind: "page", hasChildren: false },
        ]);
    });

    it("drops entries with a missing field or unknown kind, and coerces hasChildren to a boolean", () => {
        const json = JSON.stringify([
            { name: "Good", path: "good", kind: "section" },
            { name: "No path", kind: "page" },
            { name: "Bad kind", path: "x", kind: "folder" },
            { path: "no-name", kind: "page" },
        ]);
        expect(parseTreeChildren(json)).toEqual([{ name: "Good", path: "good", kind: "section", hasChildren: false }]);
    });

    it("returns [] for null, malformed JSON, or a non-array", () => {
        expect(parseTreeChildren(null)).toEqual([]);
        expect(parseTreeChildren("{not json")).toEqual([]);
        expect(parseTreeChildren('{"path":"x"}')).toEqual([]);
    });
});

describe("parseTreeSpine", () => {
    it("parses ancestor entries with their children", () => {
        const json = JSON.stringify([
            { path: "", children: [{ name: "Alpha", path: "alpha", kind: "section", hasChildren: true }] },
            {
                path: "alpha",
                children: [{ name: "Alpha Page", path: "alpha/page.md", kind: "page", hasChildren: false }],
            },
        ]);
        expect(parseTreeSpine(json)).toEqual([
            { path: "", children: [{ name: "Alpha", path: "alpha", kind: "section", hasChildren: true }] },
            {
                path: "alpha",
                children: [{ name: "Alpha Page", path: "alpha/page.md", kind: "page", hasChildren: false }],
            },
        ]);
    });

    it("tolerates entries with missing children and returns [] on malformed input", () => {
        expect(parseTreeSpine(JSON.stringify([{ path: "a" }]))).toEqual([{ path: "a", children: [] }]);
        expect(parseTreeSpine(null)).toEqual([]);
        expect(parseTreeSpine("nope")).toEqual([]);
    });
});

describe("activeNodePath", () => {
    it("maps a folder index.md to its section path (the index is folded into the section)", () => {
        expect(activeNodePath("engineering/index.md")).toBe("engineering");
        expect(activeNodePath("a/b/index.md")).toBe("a/b");
    });

    it("maps the root index.md (or empty) to no node", () => {
        expect(activeNodePath("index.md")).toBe("");
        expect(activeNodePath("")).toBe("");
    });

    it("maps any other page to its own path", () => {
        expect(activeNodePath("engineering/runbook.md")).toBe("engineering/runbook.md");
        expect(activeNodePath("home.md")).toBe("home.md");
    });
});
