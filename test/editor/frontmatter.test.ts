import { describe, expect, it } from "vitest";
import {
    frontmatterName,
    joinFrontmatter,
    setFrontmatterName,
    splitFrontmatter,
} from "../../src/TestApp/Editor/frontmatter.js";

describe("splitFrontmatter", (): void => {
    it("given a document with YAML frontmatter, when split, then the frontmatter and body are separated", (): void => {
        const result = splitFrontmatter("---\nname: Test\ncover-image: assets/x.png\n---\n\n# Heading\n\nBody.");

        expect(result).toEqual({
            frontmatter: "---\nname: Test\ncover-image: assets/x.png\n---",
            body: "# Heading\n\nBody.",
        });
    });

    it("given a document with no frontmatter, when split, then the whole text is the body", (): void => {
        expect(splitFrontmatter("# Heading\n\nBody.")).toEqual({ frontmatter: null, body: "# Heading\n\nBody." });
    });

    it("given a leading thematic break with no closing delimiter, when split, then it is treated as body", (): void => {
        // A document that opens with a horizontal rule is not frontmatter (no closing `---`).
        expect(splitFrontmatter("---\n\nJust content, no closing fence.")).toEqual({
            frontmatter: null,
            body: "---\n\nJust content, no closing fence.",
        });
    });

    it("given frontmatter only, when split, then the body is empty", (): void => {
        expect(splitFrontmatter("---\nname: Test\n---\n")).toEqual({ frontmatter: "---\nname: Test\n---", body: "" });
    });
});

describe("joinFrontmatter", (): void => {
    it("given frontmatter and a body, when joined, then they are separated by a blank line", (): void => {
        expect(joinFrontmatter("---\nname: Test\n---", "# Heading")).toBe("---\nname: Test\n---\n\n# Heading");
    });

    it("given no frontmatter, when joined, then the body is returned unchanged", (): void => {
        expect(joinFrontmatter(null, "# Heading")).toBe("# Heading");
    });
});

describe("frontmatter round-trip", (): void => {
    it("given a document, when split and re-joined with an edited body, then the frontmatter is preserved verbatim", (): void => {
        const original = "---\nname: Test\nmeta: meta/x.meta/meta.yaml\n---\n\n# Heading";
        const { frontmatter, body } = splitFrontmatter(original);
        const editedBody = `${body}\n\nA new paragraph.`;

        expect(joinFrontmatter(frontmatter, editedBody)).toBe(
            "---\nname: Test\nmeta: meta/x.meta/meta.yaml\n---\n\n# Heading\n\nA new paragraph.",
        );
    });
});

describe("frontmatterName", (): void => {
    it("given a name field, when read, then it returns the value", (): void => {
        expect(frontmatterName("---\nname: Aruba Central - Troubleshooting\nmeta: x\n---")).toBe(
            "Aruba Central - Troubleshooting",
        );
    });

    it("given a quoted name, when read, then the quotes are stripped and escapes resolved", (): void => {
        expect(frontmatterName('---\nname: "A: title"\n---')).toBe("A: title");
        expect(frontmatterName("---\nname: 'O''Brien'\n---")).toBe("O'Brien");
    });

    it("given no name field (or no frontmatter), when read, then it returns null", (): void => {
        expect(frontmatterName("---\nmeta: x\n---")).toBeNull();
        expect(frontmatterName(null)).toBeNull();
    });
});

describe("setFrontmatterName", (): void => {
    it("given an existing name, when set, then only that line changes (rest preserved)", (): void => {
        expect(setFrontmatterName("---\nname: Old\nmeta: meta/x.yaml\n---", "New Title")).toBe(
            "---\nname: New Title\nmeta: meta/x.yaml\n---",
        );
    });

    it("given frontmatter without a name, when set, then a name line is inserted after the opening fence", (): void => {
        expect(setFrontmatterName("---\nmeta: meta/x.yaml\n---", "Title")).toBe(
            "---\nname: Title\nmeta: meta/x.yaml\n---",
        );
    });

    it("given no frontmatter, when set, then a frontmatter block is created", (): void => {
        expect(setFrontmatterName(null, "Title")).toBe("---\nname: Title\n---");
    });

    it("given a value needing quoting, when set, then it is double-quoted and escaped", (): void => {
        expect(setFrontmatterName("---\nname: x\n---", "Has: colon")).toBe('---\nname: "Has: colon"\n---');
        expect(setFrontmatterName("---\nname: x\n---", 'Quote " here')).toBe('---\nname: "Quote \\" here"\n---');
    });

    it("given a set name, when read back, then it round-trips", (): void => {
        for (const title of ["Plain Title", "Has: colon", "HPE/Aruba Guides", 'with "quotes"']) {
            expect(frontmatterName(setFrontmatterName(null, title))).toBe(title);
        }
    });
});
