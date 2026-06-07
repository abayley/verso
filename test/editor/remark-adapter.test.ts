import { describe, expect, it } from "vitest";
import { parseMarkdown } from "../../src/TestApp/Editor/markdown-parse.js";
import { parseMarkdownWithRemark } from "../../src/TestApp/Editor/remark-adapter.js";

describe("parseMarkdownWithRemark", (): void => {
    it("given supported Markdown, when parsed through remark, then it matches the editor document parser", (): void => {
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

        expect(parseMarkdownWithRemark(markdown)).toEqual(parseMarkdown(markdown));
    });

    it("given unsupported Markdown, when parsed through remark, then it rejects the unsupported node", (): void => {
        expect((): void => {
            parseMarkdownWithRemark("<script>alert(1)</script>");
        }).toThrow("Unsupported Markdown node for editor subset: html");
    });
});
