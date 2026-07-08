import { render } from "lit";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { chromeButton, chromeDropdown, chromeIcon, chromeTabs } from "../../src/Verso/Editor/chrome.js";

let host: HTMLDivElement;

beforeEach((): void => {
    host = document.createElement("div");
    document.body.replaceChildren(host);
});

describe("chrome helpers (Lit mirror of Verso.Chrome)", (): void => {
    it("given a quiet control, when rendered, then it is a ghost small basecoat button", (): void => {
        render(chromeButton("quiet", "Edit", {}), host);
        const button = host.querySelector("button");
        expect(button?.className).toBe("btn");
        expect(button?.dataset["variant"]).toBe("ghost");
        expect(button?.dataset["size"]).toBe("sm");
        expect(button?.getAttribute("type")).toBe("button");
        expect(button?.textContent?.trim()).toBe("Edit");
    });

    it("given a primary action, when rendered, then it is the default variant", (): void => {
        render(chromeButton("primary", "Publish", {}), host);
        const button = host.querySelector("button");
        expect(button?.dataset["variant"]).toBeUndefined();
        expect(button?.dataset["size"]).toBe("sm");
    });

    it("given an icon control with options, when rendered, then label, tooltip, and click wiring apply", (): void => {
        const onClick = vi.fn();
        render(chromeButton("icon", chromeIcon("trash"), { ariaLabel: "Trash", tooltip: "Trash", onClick }), host);
        const button = host.querySelector("button");
        expect(button?.dataset["size"]).toBe("icon-sm");
        expect(button?.getAttribute("aria-label")).toBe("Trash");
        expect(button?.dataset["tooltip"]).toBe("Trash");
        button?.click();
        expect(onClick).toHaveBeenCalledTimes(1);
    });

    it("given an icon, when rendered, then it references the external sprite", (): void => {
        render(chromeIcon("bold"), host);
        const svg = host.querySelector("svg");
        expect(svg?.getAttribute("class")).toBe("chrome-icon");
        expect(svg?.querySelector("use")?.getAttribute("href")).toBe("/static/editor/icons.svg#i-bold");
    });

    it("given a dropdown, when rendered, then the basecoat wiring is complete", (): void => {
        render(
            chromeDropdown({
                id: "theme-menu",
                intent: "quiet",
                trigger: "Shadcn",
                items: [
                    { value: "shadcn", label: "Shadcn" },
                    { value: "studio", label: "Studio" },
                ],
                onSelect: (): void => {},
            }),
            host,
        );
        const trigger = host.querySelector("#theme-menu-trigger");
        const popover = host.querySelector("#theme-menu-popover");
        const menu = host.querySelector("#theme-menu-menu");
        expect(host.querySelector(".dropdown-menu")?.id).toBe("theme-menu");
        expect(trigger?.getAttribute("aria-haspopup")).toBe("menu");
        expect(trigger?.getAttribute("aria-controls")).toBe("theme-menu-menu");
        expect(trigger?.getAttribute("aria-expanded")).toBe("false");
        expect(popover?.hasAttribute("data-popover")).toBe(true);
        expect(popover?.getAttribute("aria-hidden")).toBe("true");
        expect(menu?.getAttribute("role")).toBe("menu");
        expect(menu?.getAttribute("aria-labelledby")).toBe("theme-menu-trigger");
        const items = [...host.querySelectorAll('[role="menuitem"]')];
        expect(items.map((item) => item.getAttribute("data-value"))).toEqual(["shadcn", "studio"]);
    });

    it("given a dropdown selection, when a menu item is clicked, then onSelect receives the value", (): void => {
        const onSelect = vi.fn();
        render(
            chromeDropdown({
                id: "m",
                intent: "quiet",
                trigger: "t",
                items: [{ value: "a", label: "A" }],
                onSelect,
            }),
            host,
        );
        (host.querySelector('[role="menuitem"]') as HTMLButtonElement).click();
        expect(onSelect).toHaveBeenCalledWith("a");
    });

    it("given tabs, when rendered, then the tablist wiring is complete and clicks report the value", (): void => {
        const onSelect = vi.fn();
        render(
            chromeTabs({
                id: "mode-tabs",
                entries: [
                    { value: "visual", label: "Visual", selected: true },
                    { value: "markdown", label: "Markdown", selected: false },
                ],
                onSelect,
            }),
            host,
        );
        const list = host.querySelector('[role="tablist"]');
        expect(list?.getAttribute("data-variant")).toBe("line");
        const tabs = [...host.querySelectorAll('[role="tab"]')];
        expect(tabs.map((tab) => tab.getAttribute("aria-selected"))).toEqual(["true", "false"]);
        (tabs[1] as HTMLButtonElement).click();
        expect(onSelect).toHaveBeenCalledWith("markdown");
    });
});
