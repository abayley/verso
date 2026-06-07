import { describe, expect, it } from "vitest";
import { renderMarkdown } from "../../src/TestApp/Editor/markdown-render.js";

describe("renderMarkdown", (): void => {
    it("renders the supported block and inline subset", (): void => {
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
        ].join("\n");

        expect(renderMarkdown(markdown)).toBe(
            "<h1>Heading</h1>" +
                '<p>Paragraph with <strong>strong</strong>, <em>emphasis</em>, <code>code</code>, and <a href="/target">link</a>.</p>' +
                "<ul><li>first</li><li>second</li></ul>" +
                "<ol><li>ordered</li><li>list</li></ol>",
        );
    });

    it("escapes unsupported raw HTML", (): void => {
        expect(renderMarkdown("<script>alert(1)</script>")).toBe("<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>");
    });
});
