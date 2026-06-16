import { describe, expect, it } from "vitest";
import { parseMarkdown } from "../../src/TestApp/Editor/markdown-parse.js";
import { renderMarkdown } from "../../src/TestApp/Editor/markdown-render.js";
import { documentFromElements, documentToMarkdown } from "../../src/TestApp/Editor/markdown-serialise.js";

describe("footnote parsing", (): void => {
    it("given an inline reference with a matching definition, when parsed, then the reference becomes a custom footnote inline node", (): void => {
        // GFM only treats `[^a]` as a reference when a matching `[^a]:` definition exists.
        const document = parseMarkdown(["Text[^a] end.", "", "[^a]: Def."].join("\n"));

        expect(document.blocks[0]).toEqual({
            children: [
                { text: "Text", type: "text" },
                { data: { footnoteId: "a" }, extension: "footnote", type: "custom" },
                { text: " end.", type: "text" },
            ],
            type: "paragraph",
        });
    });

    it("given a definition, when parsed, then it becomes a custom footnote block carrying its body", (): void => {
        expect(parseMarkdown("[^a]: First **def**.")).toEqual({
            blocks: [
                {
                    children: [
                        {
                            children: [
                                { text: "First ", type: "text" },
                                { children: [{ text: "def", type: "text" }], type: "strong" },
                                { text: ".", type: "text" },
                            ],
                            type: "paragraph",
                        },
                    ],
                    data: { footnoteId: "a" },
                    extension: "footnote",
                    type: "custom",
                },
            ],
        });
    });
});

describe("footnote rendering", (): void => {
    it("given a reference and definition, when rendered, then numbered superscripts link to a collected list", (): void => {
        const markdown = ["Text[^a] and[^b].", "", "[^a]: First.", "", "[^b]: Second."].join("\n");

        expect(renderMarkdown(markdown)).toBe(
            "<p>Text" +
                '<sup class="markdown-footnote-ref" id="fnref-a"><a href="#fn-a">1</a></sup>' +
                " and" +
                '<sup class="markdown-footnote-ref" id="fnref-b"><a href="#fn-b">2</a></sup>' +
                ".</p>" +
                '<section class="markdown-footnotes"><ol>' +
                '<li id="fn-a"><p>First.</p><a class="markdown-footnote-backref" href="#fnref-a">↩</a></li>' +
                '<li id="fn-b"><p>Second.</p><a class="markdown-footnote-backref" href="#fnref-b">↩</a></li>' +
                "</ol></section>",
        );
    });

    it("given no footnotes, when rendered, then the default per-block rendering applies", (): void => {
        expect(renderMarkdown("Plain paragraph.")).toBe("<p>Plain paragraph.</p>");
    });
});

describe("footnote Markdown round-trip", (): void => {
    it("given references and definitions, when parsed and serialised, then the source round-trips", (): void => {
        const markdown = ["Text[^a] and[^b].", "", "[^a]: First.", "", "[^b]: Second."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });

    it("given a reference inside strong, when parsed and serialised, then the reference round-trips", (): void => {
        const markdown = ["A **strong[^a]** end.", "", "[^a]: Def."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });

    it("given a multi-paragraph definition, when parsed and serialised, then the source round-trips", (): void => {
        const markdown = ["Text[^a].", "", "[^a]: First paragraph.", "", "    Second paragraph."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("footnote DOM serialisation", (): void => {
    it("given a reference superscript element, when serialised, then it becomes a [^id] reference", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<p>Text<sup class="markdown-footnote-ref" data-footnote-id="a">1</sup> end.</p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("Text[^a] end.");
    });

    it("given a definition element, when serialised, then it becomes a [^id]: definition", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<div class="markdown-footnote-def" data-footnote-id="a">' +
            '<div class="markdown-footnote-def-body"><p>Body <strong>text</strong>.</p></div>' +
            "</div>";

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("[^a]: Body **text**.");
    });
});
