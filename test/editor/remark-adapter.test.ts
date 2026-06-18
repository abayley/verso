import { describe, expect, it } from "vitest";
import { parseMarkdownLocally } from "../../src/TestApp/Editor/markdown-parse-local.js";
import { markdownHasRawHtml, parseMarkdownWithRemark } from "../../src/TestApp/Editor/remark-adapter.js";

describe("parseMarkdownWithRemark", (): void => {
    it("given supported Markdown, when parsed through remark, then it matches the legacy local parser", (): void => {
        const markdown = [
            "# Heading",
            "",
            "Paragraph with **strong**, *emphasis*, `code`, and [link](/target).",
            "",
            "- first",
            "- second",
            "",
            "1. ordered",
            "2. list",
            "",
            "---",
        ].join("\n");

        expect(parseMarkdownWithRemark(markdown)).toEqual(parseMarkdownLocally(markdown));
    });

    it("given unsupported Markdown, when parsed through remark, then it rejects the unsupported node", (): void => {
        expect((): void => {
            parseMarkdownWithRemark("<script>alert(1)</script>");
        }).toThrow("Unsupported Markdown node for editor subset: html");
    });
});

describe("markdownHasRawHtml", (): void => {
    it.each([
        ["an HTML comment", "# H\n\n<!-- export note -->"],
        ["an inline tag", "before <span>x</span> after"],
        ["a block tag", '<div class="grid">x</div>'],
    ])("given %s, when checked, then it reports raw HTML", (_name, markdown): void => {
        expect(markdownHasRawHtml(markdown)).toBe(true);
    });

    it.each([
        ["plain Markdown", "# Heading\n\nA paragraph with **bold**."],
        ["an autolink (not raw HTML)", "see <https://example.com> for more"],
    ])("given %s, when checked, then it reports no raw HTML", (_name, markdown): void => {
        expect(markdownHasRawHtml(markdown)).toBe(false);
    });
});
