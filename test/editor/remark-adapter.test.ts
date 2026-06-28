import { describe, expect, it } from "vitest";
import { parseMarkdownLocally } from "../../src/Verso/Editor/markdown-parse-local.js";
import { badgeSpans, parseMarkdownWithRemark, rawHtmlSpans } from "../../src/Verso/Editor/remark-adapter.js";

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

describe("rawHtmlSpans", (): void => {
    it("given inline HTML, when scanned, then each tag's verbatim span is found by source offset", (): void => {
        const markdown = "a <span>x</span> b";
        const spans = rawHtmlSpans(markdown);

        expect(spans.map((span): string => span.value)).toEqual(["<span>", "</span>"]);
        expect(markdown.slice(spans[0]?.start, spans[0]?.end)).toBe("<span>");
    });

    it("given a block HTML comment, when scanned, then its span is found", (): void => {
        expect(rawHtmlSpans("# H\n\n<!-- c -->").map((span): string => span.value)).toEqual(["<!-- c -->"]);
    });

    it("classifies block-level HTML (own line) as block and inline tags as inline", (): void => {
        const spans = rawHtmlSpans("![a](x.png)\n<!-- c -->\n\nsome <strong>x</strong> text");

        expect(
            spans.map((span): { value: string; block: boolean } => ({ block: span.block, value: span.value })),
        ).toEqual([
            { block: true, value: "<!-- c -->" },
            { block: false, value: "<strong>" },
            { block: false, value: "</strong>" },
        ]);
    });

    it.each([
        ["plain Markdown", "# Heading\n\ntext"],
        ["an autolink (a link, not raw HTML)", "see <https://example.com>"],
    ])("given %s, when scanned, then there are no raw-HTML spans", (_name, markdown): void => {
        expect(rawHtmlSpans(markdown)).toEqual([]);
    });
});

describe("badgeSpans", (): void => {
    it("finds a badge's text, colour and source span", (): void => {
        const markdown = "x `TODO`{.badge.yellow} y";
        const spans = badgeSpans(markdown);

        expect(spans).toEqual([{ colour: "yellow", end: 23, start: 2, text: "TODO" }]);
        expect(markdown.slice(spans[0]?.start, spans[0]?.end)).toBe("`TODO`{.badge.yellow}");
    });

    it.each([
        ["a plain code span", "`code`"],
        ["a non-badge attribute list", "`code`{.other}"],
        ["a space before the brace", "`code` {.badge.red}"],
    ])("given %s, when scanned, then there are no badge spans", (_name, markdown): void => {
        expect(badgeSpans(markdown)).toEqual([]);
    });
});
