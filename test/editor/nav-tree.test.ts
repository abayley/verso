import { describe, expect, it } from "vitest";
import { activeNodePath, parseTreeChildren, parseTreeSpine } from "../../src/TestApp/Editor/nav-tree.js";

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
