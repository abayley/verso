import { describe, expect, it } from "vitest";
import { CALLOUT_KINDS, calloutKindFromClassName, calloutTitle } from "../../src/Verso/Editor/callout.js";

describe("Callout", (): void => {
    it("given the callout module, when its kinds are read, then the five shared kinds and their default titles are provided", (): void => {
        expect(CALLOUT_KINDS.map((kind) => [kind, calloutTitle(kind)])).toEqual([
            ["note", "Note"],
            ["tip", "Tip"],
            ["important", "Important"],
            ["warning", "Warning"],
            ["caution", "Caution"],
        ]);
    });

    it("given a Callout class prefix, when a kind is decoded, then the matching kind is returned", (): void => {
        const element = document.createElement("div");
        element.className = "markdown-alert markdown-alert-warning";

        expect(calloutKindFromClassName(element.classList, "markdown-alert")).toBe("warning");
        expect(calloutKindFromClassName(element.classList, "markdown-collapsible")).toBeNull();
    });
});
