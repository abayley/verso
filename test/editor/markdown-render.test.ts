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

    it("given raw HTML, when rendering Markdown, then it rejects the unsupported node", (): void => {
        expect((): void => {
            renderMarkdown("<script>alert(1)</script>");
        }).toThrow("Unsupported Markdown node for editor subset: html");
    });

    it("renders horizontal rules", (): void => {
        expect(renderMarkdown("---")).toBe("<hr>");
    });

    it("given fenced code Markdown, when rendering, then it renders a preformatted code block", (): void => {
        expect(renderMarkdown(["```typescript", "const value = 1 < 2;", "```"].join("\n"))).toBe(
            '<pre><code class="language-typescript">const value = 1 &lt; 2;</code></pre>',
        );
    });

    it("given blockquote Markdown, when rendering, then it renders a blockquote", (): void => {
        expect(renderMarkdown("> Quoted **text**.")).toBe(
            "<blockquote><p>Quoted <strong>text</strong>.</p></blockquote>",
        );
    });
});
