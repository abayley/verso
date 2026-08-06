import { beforeEach, describe, expect, it } from "vitest";
import {
    activeNodePath,
    type NavTreeOptions,
    NavTreePanel,
    parseTreeChildren,
    parseTreeSpine,
} from "../../src/Verso/Editor/nav-tree.js";
import type { MoveOperation, ServerClient, TrashEntry, TreeNodeData } from "../../src/Verso/Editor/server-client.js";

/** Builds a nav panel over a small fixed tree (root -> Engineering[Runbook], Guide), open at Runbook. */
function mountNav(overrides: Partial<Omit<NavTreeOptions, "client">> & { client?: Partial<ServerClient> } = {}): {
    panel: HTMLElement;
    navigateCalls: string[];
} {
    const navigateCalls: string[] = [];
    const eng: TreeNodeData = { hasChildren: true, kind: "section", name: "Engineering", path: "engineering" };
    const guide: TreeNodeData = { hasChildren: true, kind: "section", name: "Guide", path: "guide" };
    const runbook: TreeNodeData = {
        hasChildren: false,
        kind: "page",
        name: "Runbook",
        path: "engineering/runbook.md",
    };
    const { client: clientOverrides, ...optionOverrides } = overrides;
    const client: ServerClient = {
        createTreeNode: async (): Promise<{ ok: false; message: string }> => ({ ok: false, message: "Create failed." }),
        deleteTrashEntry: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        deleteTreeNode: async (): Promise<{ ok: true; value: { status: "deleted" } }> => ({
            ok: true,
            value: { status: "deleted" },
        }),
        discardDraft: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        emptyTrash: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        loadTreeChildren: async (): Promise<{ ok: true; value: [] }> => ({ ok: true, value: [] }),
        listMoves: async (): Promise<{ ok: true; value: [] }> => ({ ok: true, value: [] }),
        listTrash: async (): Promise<{ ok: true; value: [] }> => ({ ok: true, value: [] }),
        loadMarkdown: async (): Promise<{ ok: true; value: string }> => ({ ok: true, value: "" }),
        moveTreeNode: async (): Promise<{ ok: true; value: { changed: number } }> => ({
            ok: true,
            value: { changed: 0 },
        }),
        restoreTrashEntry: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        searchPages: async (): Promise<{
            ok: true;
            value: { enabled: boolean; pending: number; results: [] };
        }> => ({ ok: true, value: { enabled: false, pending: 0, results: [] } }),
        saveDocument: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        saveDraft: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        syncImageTitles: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        undoMove: async (): Promise<{ ok: true; value: undefined }> => ({ ok: true, value: undefined }),
        uploadAttachment: async (): Promise<{ ok: true; value: string }> => ({ ok: true, value: "assets/file" }),
        ...clientOverrides,
    };
    const options: NavTreeOptions = {
        client,
        documentPath: "engineering/runbook.md",
        spine: [
            { children: [eng, guide], path: "" },
            { children: [runbook], path: "engineering" },
        ],
        navigate: (path: string): void => {
            navigateCalls.push(path);
        },
        registerTooltip: (): void => {},
        notify: (): void => {},
        ...optionOverrides,
    };
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

/** Installs a fresh in-memory web storage stub (happy-dom does not provide one). */
function installStorageStub(name: "localStorage" | "sessionStorage"): void {
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
    Object.defineProperty(window, name, { configurable: true, value: stub });
}

describe("NavTreePanel navigation (RFC-0026)", () => {
    beforeEach((): void => {
        installStorageStub("localStorage");
        installStorageStub("sessionStorage");
        document.body.replaceChildren();
    });

    it("given cached children for an expanded branch, when mounted, then the branch renders before its freshness check completes", () => {
        window.localStorage.setItem("editor-nav-expanded", JSON.stringify(["guide"]));
        window.sessionStorage.setItem(
            "editor-nav-children",
            JSON.stringify({
                guide: [{ hasChildren: false, kind: "page", name: "Cached page", path: "guide/cached.md" }],
            }),
        );
        const pending = new Promise<{ ok: true; value: [] }>((): void => {});

        const { panel } = mountNav({ client: { loadTreeChildren: (): Promise<{ ok: true; value: [] }> => pending } });

        expect(navLabel(panel, "Cached page")).toBeInstanceOf(HTMLElement);
    });

    it("given cached children for expanded branches, when mounted, then freshness checks run in parallel and replace changed rows", async () => {
        window.localStorage.setItem("editor-nav-expanded", JSON.stringify(["guide", "servers"]));
        window.sessionStorage.setItem(
            "editor-nav-children",
            JSON.stringify({
                guide: [{ hasChildren: false, kind: "page", name: "Old guide", path: "guide/old.md" }],
                servers: [{ hasChildren: false, kind: "page", name: "Server page", path: "servers/page.md" }],
            }),
        );
        const responses = new Map<string, (result: { ok: true; value: TreeNodeData[] }) => void>();
        const requested: string[] = [];
        const engineering: TreeNodeData = {
            hasChildren: true,
            kind: "section",
            name: "Engineering",
            path: "engineering",
        };
        const guide: TreeNodeData = { hasChildren: true, kind: "section", name: "Guide", path: "guide" };
        const servers: TreeNodeData = { hasChildren: true, kind: "section", name: "Servers", path: "servers" };
        const runbook: TreeNodeData = {
            hasChildren: false,
            kind: "page",
            name: "Runbook",
            path: "engineering/runbook.md",
        };

        const { panel } = mountNav({
            spine: [
                { children: [engineering, guide, servers], path: "" },
                { children: [runbook], path: "engineering" },
            ],
            client: {
                loadTreeChildren: (path: string): Promise<{ ok: true; value: TreeNodeData[] }> => {
                    requested.push(path);
                    return new Promise<{ ok: true; value: TreeNodeData[] }>((resolve): void => {
                        responses.set(path, resolve);
                    });
                },
            },
        });

        expect(requested).toEqual(["guide", "servers"]);
        responses.get("guide")?.({
            ok: true,
            value: [{ hasChildren: false, kind: "page", name: "Current guide", path: "guide/current.md" }],
        });
        responses.get("servers")?.({
            ok: true,
            value: [{ hasChildren: false, kind: "page", name: "Server page", path: "servers/page.md" }],
        });
        await new Promise((resolve): void => {
            setTimeout(resolve);
        });

        expect(navLabel(panel, "Current guide")).toBeInstanceOf(HTMLElement);
        expect(panel.textContent).not.toContain("Old guide");
    });

    it("given a section label click, when opening, then the section expands and the browser navigates", () => {
        const { panel, navigateCalls } = mountNav();

        navLabel(panel, "Guide").dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(navigateCalls).toHaveLength(1);
        expect(expandedPaths()).toContain("guide");
    });

    it("given a tree row, when its padding is clicked, then the browser navigates to the node", () => {
        const { panel, navigateCalls } = mountNav();
        const row = navLabel(panel, "Guide").closest(".markdown-editor__nav-row");

        row?.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(navigateCalls).toEqual(["guide/index.md"]);
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
        const { panel } = mountNav({
            client: { listMoves: async (): Promise<{ ok: false; message: string }> => ({ ok: false, message: "x" }) },
        });

        const trigger = panel.querySelector("#nav-undo-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        await new Promise((resolve) => setTimeout(resolve));

        const labels = [...panel.querySelectorAll('#nav-undo-menu [role="menuitem"]')].map(
            (item): string => item.textContent?.trim() ?? "",
        );
        expect(labels).toContain("Couldn’t reach the server.");
    });

    it("given an unreachable server, when the trash dropdown opens, then it shows the error item (view-all stays)", async () => {
        const { panel } = mountNav({
            client: { listTrash: async (): Promise<{ ok: false; message: string }> => ({ ok: false, message: "x" }) },
        });

        const trigger = panel.querySelector("#nav-trash-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        await new Promise((resolve) => setTimeout(resolve));

        const labels = [...panel.querySelectorAll('#nav-trash-menu [role="menuitem"]')].map(
            (item): string => item.textContent?.trim() ?? "",
        );
        expect(labels).toContain("Couldn’t reach the server.");
        expect(labels).toContain("View all in trash…");
    });

    it("given a new navigation tree, when mounted, then it does not load trash before the menu is opened", () => {
        let listCalls = 0;

        mountNav({
            client: {
                listTrash: async (): Promise<{ ok: true; value: [] }> => {
                    listCalls += 1;
                    return { ok: true, value: [] };
                },
            },
        });

        expect(listCalls).toBe(0);
    });

    it("given a new navigation tree, when mounted, then it does not load moves before the menu is opened", () => {
        let listCalls = 0;

        mountNav({
            client: {
                listMoves: async (): Promise<{ ok: true; value: [] }> => {
                    listCalls += 1;
                    return { ok: true, value: [] };
                },
            },
        });

        expect(listCalls).toBe(0);
    });

    it("given trash is still loading, when the trash dropdown opens again, then it reuses the pending request", async () => {
        let listCalls = 0;
        let finishListing: (result: { ok: true; value: TrashEntry[] }) => void = (): void => {};
        const listing = new Promise<{ ok: true; value: TrashEntry[] }>((resolve): void => {
            finishListing = resolve;
        });
        const { panel } = mountNav({
            client: {
                listTrash: (): Promise<{ ok: true; value: TrashEntry[] }> => {
                    listCalls += 1;
                    return listing;
                },
            },
        });

        const trigger = panel.querySelector("#nav-trash-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(listCalls).toBe(1);
        finishListing({ ok: true, value: [] });
        await listing;
    });

    it("given moves are still loading, when the undo dropdown opens again, then it reuses the pending request", async () => {
        let listCalls = 0;
        let finishListing: (result: { ok: true; value: MoveOperation[] }) => void = (): void => {};
        const listing = new Promise<{ ok: true; value: MoveOperation[] }>((resolve): void => {
            finishListing = resolve;
        });
        const { panel } = mountNav({
            client: {
                listMoves: (): Promise<{ ok: true; value: MoveOperation[] }> => {
                    listCalls += 1;
                    return listing;
                },
            },
        });

        const trigger = panel.querySelector("#nav-undo-menu-trigger") as HTMLElement;
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));
        trigger.dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(listCalls).toBe(1);
        finishListing({ ok: true, value: [] });
        await listing;
    });

    it("given logged moves, when the undo dropdown opens, then a view-all item linking the undo page is last", async () => {
        const { panel } = mountNav({
            client: {
                listMoves: async (): Promise<{ ok: true; value: { seq: number; from: string; to: string }[] }> => ({
                    ok: true,
                    value: [{ seq: 0, from: "a", to: "b/a" }],
                }),
            },
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
