import { describe, expect, it } from "vitest";
import { commonContentPipeline } from "../../src/Verso/Editor/register-extensions.js";
import { parseMarkdownWithRemark } from "../../src/Verso/Editor/remark-adapter.js";

const parseMarkdown = (markdown: string) => parseMarkdownWithRemark(markdown, commonContentPipeline);
const { documentFromElements, documentToMarkdown } = commonContentPipeline;

describe("collapsible parsing", (): void => {
    it("given a collapsed note with a title and body, when parsed, then it becomes a custom collapsible block", (): void => {
        const markdown = ['??? note "Optional title"', "", "    Body **text** here."].join("\n");

        expect(parseMarkdown(markdown)).toEqual({
            blocks: [
                {
                    children: [
                        {
                            children: [
                                { text: "Body ", type: "text" },
                                { children: [{ text: "text", type: "text" }], type: "strong" },
                                { text: " here.", type: "text" },
                            ],
                            type: "paragraph",
                        },
                    ],
                    data: { collapsibleType: "note", open: false, title: "Optional title" },
                    extension: "collapsible",
                    type: "custom",
                },
            ],
        });
    });

    it("given a `???+` marker without a title, when parsed, then it is open with a null title", (): void => {
        const markdown = ["???+ tip", "", "    Body."].join("\n");

        expect(parseMarkdown(markdown)).toEqual({
            blocks: [
                {
                    children: [{ children: [{ text: "Body.", type: "text" }], type: "paragraph" }],
                    data: { collapsibleType: "tip", open: true, title: null },
                    extension: "collapsible",
                    type: "custom",
                },
            ],
        });
    });

    it.each([
        ["note"],
        ["tip"],
        ["important"],
        ["warning"],
        ["caution"],
    ])("given a `??? %s` collapsible, when parsed, then its type is carried", (kind: string): void => {
        const document = parseMarkdown([`??? ${kind}`, "", "    Body."].join("\n"));

        expect(document.blocks[0]).toMatchObject({
            data: { collapsibleType: kind },
            extension: "collapsible",
            type: "custom",
        });
    });

    it("given a multi-paragraph body, when parsed, then each body block is kept", (): void => {
        const document = parseMarkdown(["??? note", "", "    First.", "", "    Second."].join("\n"));

        expect(document.blocks[0]).toMatchObject({
            children: [
                { children: [{ text: "First.", type: "text" }], type: "paragraph" },
                { children: [{ text: "Second.", type: "text" }], type: "paragraph" },
            ],
            extension: "collapsible",
        });
    });

    it("given an unknown type, when parsed, then it stays a plain paragraph", (): void => {
        const document = parseMarkdown(["??? unknown", "", "    Body."].join("\n"));

        expect(document.blocks[0]?.type).toBe("paragraph");
    });

    it("given a marker without an indented body, when parsed, then it stays a plain paragraph", (): void => {
        const document = parseMarkdown("??? note");

        expect(document.blocks[0]?.type).toBe("paragraph");
    });

    it("given trailing text after the title, when parsed, then it stays a plain paragraph", (): void => {
        const document = parseMarkdown(['??? note "Title" extra', "", "    Body."].join("\n"));

        expect(document.blocks[0]?.type).toBe("paragraph");
    });
});

describe("collapsible Markdown round-trip", (): void => {
    it("given a titled multi-paragraph collapsible, when parsed and serialised, then the source round-trips", (): void => {
        const markdown = ['??? note "Title"', "", "    First **paragraph**.", "", "    Second paragraph."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });

    it("given an open untitled collapsible, when parsed and serialised, then the source round-trips", (): void => {
        const markdown = ["???+ warning", "", "    Careful."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("collapsible DOM serialisation", (): void => {
    it("given a rendered collapsible element, when serialised, then it becomes mkdocs source", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<details class="markdown-collapsible markdown-collapsible-warning" open data-title="Heads up">' +
            '<summary class="markdown-collapsible-title" contenteditable="false">Heads up</summary>' +
            '<div class="markdown-collapsible-body"><p>Be <strong>careful</strong>.</p></div>' +
            "</details>";

        expect(documentToMarkdown(documentFromElements(root.children))).toBe(
            ['???+ warning "Heads up"', "", "    Be **careful**."].join("\n"),
        );
    });

    it("given a collapsible element without a title attribute, when serialised, then no title is emitted", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<details class="markdown-collapsible markdown-collapsible-note">' +
            '<summary class="markdown-collapsible-title" contenteditable="false">Note</summary>' +
            '<div class="markdown-collapsible-body"><p>Body.</p></div>' +
            "</details>";

        expect(documentToMarkdown(documentFromElements(root.children))).toBe(["??? note", "", "    Body."].join("\n"));
    });

    it.each([
        "note",
        "tip",
        "important",
        "warning",
        "caution",
    ])("given a rendered %s collapsible, when converted from DOM, then its type and Markdown are preserved", (kind: string): void => {
        const root = document.createElement("div");
        root.innerHTML =
            `<details class="markdown-collapsible markdown-collapsible-${kind}">` +
            `<summary class="markdown-collapsible-title" contenteditable="false">${kind}</summary>` +
            '<div class="markdown-collapsible-body"><p>Body.</p></div>' +
            "</details>";
        const document_ = documentFromElements(root.children);

        expect(document_.blocks[0]).toMatchObject({
            data: { collapsibleType: kind },
            extension: "collapsible",
            type: "custom",
        });
        expect(documentToMarkdown(document_)).toBe([`??? ${kind}`, "", "    Body."].join("\n"));
    });
});
