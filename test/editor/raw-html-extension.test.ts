import { beforeAll, describe, expect, it } from "vitest";
import { registerExtension } from "../../src/TestApp/Editor/content-extension.js";
import { parseMarkdown } from "../../src/TestApp/Editor/markdown-parse.js";
import { documentFromElements, documentToMarkdown } from "../../src/TestApp/Editor/markdown-serialise.js";
import { rawHtmlExtension } from "../../src/TestApp/Editor/raw-html-extension.js";

// Raw-HTML preservation is opt-in (the document-tree editing mode enables it); register it for this suite.
// Vitest isolates module state per file, so this does not relax the strict parse in the other suites.
beforeAll((): void => {
    registerExtension(rawHtmlExtension);
});

describe("raw HTML parsing", (): void => {
    it("given a block HTML comment, when parsed, then it becomes a preserved raw-html block", (): void => {
        expect(parseMarkdown("<!-- hidden export note -->")).toEqual({
            blocks: [{ data: { html: "<!-- hidden export note -->" }, extension: "raw-html", type: "custom" }],
        });
    });

    it("given inline HTML, when parsed, then the tags become preserved raw-html inlines around the text", (): void => {
        const document = parseMarkdown("before <strong>x</strong> after");

        expect((document.blocks[0] as { children: unknown[] }).children).toEqual([
            { text: "before ", type: "text" },
            { data: { html: "<strong>" }, extension: "raw-html", type: "custom" },
            { text: "x", type: "text" },
            { data: { html: "</strong>" }, extension: "raw-html", type: "custom" },
            { text: " after", type: "text" },
        ]);
    });
});

describe("raw HTML round-trip", (): void => {
    it.each([
        ["a comment", "<!-- a comment -->"],
        ["a multi-line comment", "<!--\nimage: assets/x.png\n-->"],
        ["inline tags", "x <strong>y</strong> z"],
    ])("given %s, when parsed and serialised, then the raw HTML round-trips verbatim", (_name, markdown): void => {
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("raw HTML DOM serialisation", (): void => {
    it("given a raw-html placeholder element, when serialised, then its verbatim HTML is emitted", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<div class="markdown-raw-html">&lt;!-- c --&gt;</div>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("<!-- c -->");
    });
});
