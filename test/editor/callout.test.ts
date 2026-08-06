import { describe, expect, it } from "vitest";
import { CALLOUT_KINDS, calloutKindFromClassName, calloutTitle } from "../../src/Verso/Editor/callout.js";

describe("Callout", (): void => {
    it("provides the five shared kinds and their default titles", (): void => {
        expect(CALLOUT_KINDS.map((kind) => [kind, calloutTitle(kind)])).toEqual([
            ["note", "Note"],
            ["tip", "Tip"],
            ["important", "Important"],
            ["warning", "Warning"],
            ["caution", "Caution"],
        ]);
    });

    it("decodes a kind from the supplied Callout class prefix", (): void => {
        const element = document.createElement("div");
        element.className = "markdown-alert markdown-alert-warning";

        expect(calloutKindFromClassName(element.classList, "markdown-alert")).toBe("warning");
        expect(calloutKindFromClassName(element.classList, "markdown-collapsible")).toBeNull();
    });
});
