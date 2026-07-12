import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MarkdownEditorElement } from "../../src/Verso/Editor/markdown-editor-element.js";

const elementName = "markdown-editor-autosave-test";

if (!customElements.get(elementName)) {
    customElements.define(elementName, MarkdownEditorElement);
}

/** The element's autosave debounce (mirrors autosaveDebounceMilliseconds). */
const debounceMilliseconds = 2000;

describe("MarkdownEditorElement autosave (RFC-0036)", (): void => {
    let fetchMock: ReturnType<typeof vi.fn>;

    beforeEach((): void => {
        document.body.textContent = "";
        installLocalStorageStub();
        Object.defineProperty(navigator, "sendBeacon", {
            configurable: true,
            value: (): boolean => true,
            writable: true,
        });
        fetchMock = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        vi.stubGlobal("fetch", fetchMock);
    });

    afterEach((): void => {
        vi.useRealTimers();
        vi.restoreAllMocks();
        vi.unstubAllGlobals();
    });

    it("given a change with versioning on, when the debounce elapses, then the raw document is PUT to the draft resource", async (): Promise<void> => {
        const editor = await createEditor({ versioning: true, markdown: "# Draft body" });

        editor.dispatchEvent(new CustomEvent("editor:changed", { bubbles: true }));
        await advance(debounceMilliseconds);

        const saveCalls = callsTo("/drafts/sec/page.md");
        expect(saveCalls.length).toBe(1);
        const [, init] = saveCalls[0] as [string, RequestInit];
        expect(init.method).toBe("PUT");
        expect(init.body).toBe("# Draft body");
        expect((init.headers as Record<string, string>)["Content-Type"]).toBe("text/markdown; charset=utf-8");
    });

    it("given rapid changes, when the debounce elapses, then only one save is sent", async (): Promise<void> => {
        const editor = await createEditor({ versioning: true, markdown: "# Debounced" });

        editor.dispatchEvent(new CustomEvent("editor:changed", { bubbles: true }));
        await advance(debounceMilliseconds - 500);
        editor.dispatchEvent(new CustomEvent("editor:changed", { bubbles: true }));
        await advance(debounceMilliseconds);

        expect(callsTo("/drafts/sec/page.md").length).toBe(1);
    });

    it("given versioning off, when the debounce elapses, then the save PUTs the page directly", async (): Promise<void> => {
        const editor = await createEditor({ versioning: false, markdown: "# Direct" });

        editor.dispatchEvent(new CustomEvent("editor:changed", { bubbles: true }));
        await advance(debounceMilliseconds);

        const saveCalls = callsTo("/documents/sec/page.md");
        expect(saveCalls.length).toBe(1);
        const [, init] = saveCalls[0] as [string, RequestInit];
        expect(init.method).toBe("PUT");
    });

    it("given a save, when it succeeds, then the save state settles to clean", async (): Promise<void> => {
        const editor = await createEditor({ versioning: true, markdown: "# Settles" });

        editor.dispatchEvent(new CustomEvent("editor:changed", { bubbles: true }));
        await advance(debounceMilliseconds);
        // the controller holds "saving" for its minimum display time before settling
        await advance(600);

        expect(editor.getAttribute("data-save-state")).toBe("clean");
    });

    it("given a save, when the server rejects it, then the save state offers a retry", async (): Promise<void> => {
        fetchMock.mockImplementation(async (): Promise<Response> => new Response(null, { status: 500 }));
        const editor = await createEditor({ versioning: true, markdown: "# Fails" });

        editor.dispatchEvent(new CustomEvent("editor:changed", { bubbles: true }));
        await advance(debounceMilliseconds);
        await advance(600);

        expect(editor.getAttribute("data-save-state")).toBe("retry");
    });

    it("given the surrounding form submits, when JavaScript is active, then it saves via fetch instead of navigating", async (): Promise<void> => {
        const editor = await createEditor({ versioning: true, markdown: "# Submitted" });
        const form = editor.closest("form") as HTMLFormElement;

        form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
        await advance(0);

        expect(callsTo("/drafts/sec/page.md").length).toBe(1);
    });

    /** Builds an editable editor inside its no-JS form shell, source mode for a cheap surface. */
    async function createEditor(options: { versioning: boolean; markdown: string }): Promise<HTMLElement> {
        vi.useFakeTimers();
        const form = document.createElement("form");
        form.setAttribute("action", "/documents/sec/page.md");
        form.setAttribute("method", "post");
        const editor = document.createElement(elementName);
        editor.setAttribute("mode", "source");
        editor.setAttribute("data-document", "sec/page.md");
        if (options.versioning) {
            editor.setAttribute("data-versioning", "");
        }
        editor.textContent = options.markdown;
        form.append(editor);
        document.body.append(form);
        await advance(0);
        return editor;
    }

    /** Advances fake timers and flushes pending microtasks. */
    async function advance(milliseconds: number): Promise<void> {
        await vi.advanceTimersByTimeAsync(milliseconds);
    }

    /** The fetch calls whose URL contains the given path. */
    function callsTo(path: string): unknown[][] {
        return fetchMock.mock.calls.filter((call): boolean => String(call[0]).includes(path));
    }
});

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
