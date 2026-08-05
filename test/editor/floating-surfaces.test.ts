import { afterEach, describe, expect, it, vi } from "vitest";
import { FloatingSurfaces, type FloatingSurfacesHandlers } from "../../src/Verso/Editor/floating-surfaces.js";

describe("FloatingSurfaces", (): void => {
    afterEach((): void => {
        document.body.textContent = "";
        vi.restoreAllMocks();
    });

    it("given a mounted bubble surface, when shown and hidden, then it renders and positions synchronously", (): void => {
        const { host, surfaces } = mountSurfaces();

        surfaces.bubble.showAt(new DOMRect(50, 60, 80, 40), {
            activeStyles: ["strong"],
            blockStyle: "heading-1",
        });

        const bubble = host.querySelector<HTMLElement>(".markdown-editor__bubble");
        expect(bubble?.hidden).toBe(false);
        expect(bubble?.querySelector(".markdown-editor__bubble-style-trigger")?.textContent?.trim()).toBe("Heading 1");
        expect(bubble?.querySelector('[aria-label="Bold"]')?.classList).toContain(
            "markdown-editor__bubble-button--active",
        );
        expect(bubble?.style.left).toBe("40px");
        expect(bubble?.style.top).toBe("88px");

        surfaces.bubble.hide();

        expect(bubble?.hidden).toBe(true);
    });

    it("given a shown slash surface, when keyboard selection changes and confirms, then it runs the command and hides", (): void => {
        const { host, surfaces } = mountSurfaces();
        const selected: string[] = [];
        surfaces.slash.showAt(new DOMRect(50, 60, 80, 40), [
            {
                label: "First",
                run: (): void => {
                    selected.push("first");
                },
            },
            {
                label: "Second",
                run: (): void => {
                    selected.push("second");
                },
            },
        ]);

        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "ArrowDown" }));

        const menu = host.querySelector<HTMLElement>(".markdown-editor__slash-menu");
        expect(menu?.querySelectorAll(".markdown-editor__slash-item")[1]?.classList).toContain(
            "markdown-editor__slash-item--active",
        );

        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter" }));

        expect(selected).toEqual(["second"]);
        expect(menu?.hidden).toBe(true);
    });

    it("given a slash command group, when its child is chosen, then the submenu opens and the child runs", (): void => {
        const { host, surfaces } = mountSurfaces();
        const selected: string[] = [];
        surfaces.slash.showAt(new DOMRect(50, 60, 80, 40), [
            {
                children: [
                    {
                        label: "Child",
                        run: (): void => {
                            selected.push("child");
                        },
                    },
                ],
                label: "Group",
            },
        ]);

        slashItem(host, "Group").click();

        const labels = Array.from(host.querySelectorAll(".markdown-editor__slash-item"), (item): string =>
            cleanSlashLabel(item.textContent),
        );
        expect(labels).toEqual(["Back", "Child"]);

        slashItem(host, "Child").click();

        expect(selected).toEqual(["child"]);
        expect(host.querySelector<HTMLElement>(".markdown-editor__slash-menu")?.hidden).toBe(true);
    });

    it("given a shown slash submenu, when Escape is pressed twice, then it returns to the root and closes", (): void => {
        const { host, surfaces } = mountSurfaces();
        surfaces.slash.showAt(new DOMRect(50, 60, 80, 40), [
            {
                children: [{ label: "Child", run: (): void => {} }],
                label: "Group",
            },
        ]);
        slashItem(host, "Group").click();

        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Escape" }));

        expect(slashItem(host, "Group")).toBeInstanceOf(HTMLElement);
        const menu = host.querySelector<HTMLElement>(".markdown-editor__slash-menu");
        expect(menu?.hidden).toBe(false);

        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Escape" }));

        expect(menu?.hidden).toBe(true);
    });

    it("given a shown slash submenu, when keyboard navigation returns and wraps upward, then it selects the last root command", (): void => {
        const { host, surfaces } = mountSurfaces();
        const selected: string[] = [];
        surfaces.slash.showAt(new DOMRect(50, 60, 80, 40), [
            {
                children: [{ label: "Child", run: (): void => {} }],
                label: "Group",
            },
            {
                label: "Last",
                run: (): void => {
                    selected.push("last");
                },
            },
        ]);
        slashItem(host, "Group").click();

        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "ArrowLeft" }));
        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "ArrowUp" }));
        host.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key: "Enter" }));

        expect(selected).toEqual(["last"]);
        expect(host.querySelector<HTMLElement>(".markdown-editor__slash-menu")?.hidden).toBe(true);
    });

    it("given a shown table surface, when its controls are used, then it forwards table actions and hides", (): void => {
        const commands: string[] = [];
        const alignments: string[] = [];
        const { host, surfaces } = mountSurfaces({
            ...inertHandlers(),
            applyTableAlignment: (align: string): void => {
                alignments.push(align);
            },
            runTableCommand: (command: string): void => {
                commands.push(command);
            },
        });

        surfaces.table.showAt(new DOMRect(50, 60, 80, 40));

        const controls = host.querySelector<HTMLElement>(".markdown-editor__table-controls");
        expect(controls?.hidden).toBe(false);
        expect(controls?.style.left).toBe("40px");
        expect(controls?.style.top).toBe("88px");
        controls?.querySelector<HTMLButtonElement>('[aria-label="Add row"]')?.click();
        controls?.querySelector<HTMLButtonElement>('[aria-label="Align centre"]')?.click();
        expect(commands).toEqual(["row-after"]);
        expect(alignments).toEqual(["center"]);

        surfaces.table.hide();

        expect(controls?.hidden).toBe(true);
    });
});

/** Mounts floating surfaces against fixed layout rectangles. */
function mountSurfaces(handlers: FloatingSurfacesHandlers = inertHandlers()): {
    host: HTMLElement;
    surfaces: FloatingSurfaces;
} {
    const host = document.createElement("div");
    document.body.append(host);
    vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockImplementation(function (this: HTMLElement): DOMRect {
        return this === host ? new DOMRect(10, 20, 500, 400) : new DOMRect(0, 0, 100, 40);
    });
    const surfaces = new FloatingSurfaces(host, handlers);
    surfaces.mount();

    return { host, surfaces };
}

/** Returns inert handlers for tests that only exercise rendering and positioning. */
function inertHandlers(): FloatingSurfacesHandlers {
    return {
        applyBadge: (): void => {},
        applyBlockStyle: (): void => {},
        applyTableAlignment: (): void => {},
        runTableCommand: (): void => {},
        toggleInlineStyle: (): void => {},
        toggleStructure: (): void => {},
    };
}

/** Returns one visible slash item by its plain label. */
function slashItem(host: HTMLElement, label: string): HTMLElement {
    const item = Array.from(host.querySelectorAll<HTMLElement>(".markdown-editor__slash-item")).find(
        (candidate): boolean => cleanSlashLabel(candidate.textContent) === label,
    );

    if (!item) {
        throw new Error(`Expected a slash item named ${label}.`);
    }

    return item;
}

/** Removes the group and back glyphs from a slash item label. */
function cleanSlashLabel(label: string | null): string {
    return (label ?? "").replace(/[‹›]/gu, "").trim();
}
