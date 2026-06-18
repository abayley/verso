import { describe, expect, it } from "vitest";
import { joinFrontmatter, splitFrontmatter } from "../../src/TestApp/Editor/frontmatter.js";

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
