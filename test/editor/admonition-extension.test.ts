import { describe, expect, it } from "vitest";
import { parseMarkdown } from "../../src/TestApp/Editor/markdown-parse.js";
import { renderMarkdown } from "../../src/TestApp/Editor/markdown-render.js";
import { documentToMarkdown } from "../../src/TestApp/Editor/markdown-serialise.js";

describe("admonition parsing", (): void => {
    it("given a NOTE alert blockquote, when parsed, then it becomes a custom admonition block", (): void => {
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
                    extension: "admonition",
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

        expect(block).toMatchObject({ data: { kind }, extension: "admonition", type: "custom" });
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

    it("given a marker-only alert, when parsed, then it becomes an admonition with an empty body", (): void => {
        expect(parseMarkdown("> [!TIP]")).toEqual({
            blocks: [
                {
                    children: [],
                    data: { kind: "tip" },
                    extension: "admonition",
                    type: "custom",
                },
            ],
        });
    });
});

describe("admonition rendering", (): void => {
    it("given a NOTE alert, when rendered, then it produces a callout with a title and body", (): void => {
        expect(renderMarkdown(["> [!NOTE]", "> Body **text**."].join("\n"))).toBe(
            '<div class="markdown-alert markdown-alert-note">' +
                '<p class="markdown-alert-title">Note</p>' +
                "<p>Body <strong>text</strong>.</p>" +
                "</div>",
        );
    });

    it("given a plain blockquote, when rendered, then it stays a blockquote", (): void => {
        expect(renderMarkdown("> Just a quote.")).toBe("<blockquote><p>Just a quote.</p></blockquote>");
    });
});

describe("admonition Markdown round-trip", (): void => {
    it("given a multi-paragraph alert, when parsed and serialised, then the GFM source round-trips", (): void => {
        const markdown = ["> [!WARNING]", "> First **paragraph**.", ">", "> Second paragraph."].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });

    it("given a marker-only alert, when parsed and serialised, then the GFM source round-trips", (): void => {
        expect(documentToMarkdown(parseMarkdown("> [!CAUTION]"))).toBe("> [!CAUTION]");
    });
});
