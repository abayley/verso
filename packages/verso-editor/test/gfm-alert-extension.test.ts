import { describe, expect, it } from "vitest";
import { commonContentPipeline } from "../src/register-extensions.js";
import { parseMarkdownWithRemark } from "../src/remark-adapter.js";

const parseMarkdown = (markdown: string) => parseMarkdownWithRemark(markdown, commonContentPipeline);
const { documentFromElements, documentToMarkdown } = commonContentPipeline;

describe("GFM alert parsing", (): void => {
    it("given a NOTE alert blockquote, when parsed, then it becomes a custom GFM alert block", (): void => {
        const markdown = ["> [!NOTE]", "> Body **text** here."].join("\n");

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
                    data: { kind: "note" },
                    extension: "gfm-alert",
                    type: "custom",
                },
            ],
        });
    });

    it.each([
        ["NOTE", "note"],
        ["TIP", "tip"],
        ["IMPORTANT", "important"],
        ["WARNING", "warning"],
        ["CAUTION", "caution"],
    ])("given a [!%s] alert, when parsed, then its kind is %s", (marker: string, kind: string): void => {
        const document = parseMarkdown([`> [!${marker}]`, "> Body."].join("\n"));
        const block = document.blocks[0];

        expect(block).toMatchObject({ data: { kind }, extension: "gfm-alert", type: "custom" });
    });

    it("given a blockquote without a marker, when parsed, then it stays a plain blockquote", (): void => {
        const document = parseMarkdown("> Just a quote.");

        expect(document.blocks[0]?.type).toBe("blockquote");
    });

    it("given a blockquote with an unknown marker, when parsed, then it stays a plain blockquote", (): void => {
        const document = parseMarkdown(["> [!UNKNOWN]", "> Body."].join("\n"));

        expect(document.blocks[0]?.type).toBe("blockquote");
    });

    it("given a marker followed by inline text on the same line, when parsed, then it stays a plain blockquote", (): void => {
        const document = parseMarkdown("> [!NOTE] inline body");

        expect(document.blocks[0]?.type).toBe("blockquote");
    });

    it("given a marker-only alert, when parsed, then it becomes a GFM alert with an empty body", (): void => {
        expect(parseMarkdown("> [!TIP]")).toEqual({
            blocks: [
                {
                    children: [],
                    data: { kind: "tip" },
                    extension: "gfm-alert",
                    type: "custom",
                },
            ],
        });
    });
});

describe("GFM alert Markdown round-trip", (): void => {
    it("given a multi-paragraph alert, when parsed and serialised, then the GFM source round-trips", (): void => {
        const markdown = ["> [!WARNING]", "> First **paragraph**.", ">", "> Second paragraph."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });

    it("given a marker-only alert, when parsed and serialised, then the GFM source round-trips", (): void => {
        expect(documentToMarkdown(parseMarkdown("> [!CAUTION]"))).toBe("> [!CAUTION]");
    });
});

describe("GFM alert DOM serialisation", (): void => {
    it("given a rendered callout element, when serialised, then it becomes a GFM alert", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<div class="markdown-alert markdown-alert-warning">' +
            '<p class="markdown-alert-title" contenteditable="false">Warning</p>' +
            '<div class="markdown-alert-body"><p>Be <strong>careful</strong>.</p></div>' +
            "</div>";

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("> [!WARNING]\n> Be **careful**.");
    });

    it("given a callout element whose title text differs, when serialised, then the kind comes from the class", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<div class="markdown-alert markdown-alert-tip">' +
            '<p class="markdown-alert-title" contenteditable="false">Anything</p>' +
            '<div class="markdown-alert-body"><p>Body.</p></div>' +
            "</div>";

        const document_ = documentFromElements(root.children);

        expect(document_.blocks[0]).toMatchObject({ data: { kind: "tip" }, extension: "gfm-alert", type: "custom" });
    });

    it.each([
        "note",
        "tip",
        "important",
        "warning",
        "caution",
    ])("given a rendered %s alert, when converted from DOM, then its kind and Markdown are preserved", (kind: string): void => {
        const root = document.createElement("div");
        root.innerHTML =
            `<div class="markdown-alert markdown-alert-${kind}">` +
            `<p class="markdown-alert-title" contenteditable="false">${kind}</p>` +
            '<div class="markdown-alert-body"><p>Body.</p></div>' +
            "</div>";
        const document_ = documentFromElements(root.children);

        expect(document_.blocks[0]).toMatchObject({ data: { kind }, extension: "gfm-alert", type: "custom" });
        expect(documentToMarkdown(document_)).toBe(`> [!${kind.toUpperCase()}]\n> Body.`);
    });
});
