import { describe, expect, it } from "vitest";
import { type ContentExtensionFor, createContentPipeline } from "../src/content-extension.js";
import { commonContentPipeline } from "../src/register-extensions.js";
import { badgeSpans, parseMarkdownWithRemark, rawHtmlSpans } from "../src/remark-adapter.js";

declare module "../src/editor-model.js" {
    interface ContentExtensionPayloads {
        "adapter-probe": { block: { source: string } };
    }
}

describe("parseMarkdownWithRemark", (): void => {
    it("given a supplied pipeline, when Markdown is parsed, then that pipeline converts the mdast", (): void => {
        const extension: ContentExtensionFor<"adapter-probe"> = {
            blockFromMdast: (node) =>
                node.type === "thematicBreak" ? { data: { source: "supplied pipeline" } } : null,
            name: "adapter-probe",
        };
        const pipeline = createContentPipeline([extension]);

        expect(parseMarkdownWithRemark("---", pipeline)).toEqual({
            blocks: [
                {
                    data: { source: "supplied pipeline" },
                    extension: "adapter-probe",
                    type: "custom",
                },
            ],
        });
    });

    it("given unsupported Markdown, when parsed through remark, then it rejects the unsupported node", (): void => {
        expect((): void => {
            parseMarkdownWithRemark("<script>alert(1)</script>", commonContentPipeline);
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

    it("given HTML on its own line and inline tags, when spans are classified, then the first is block and the rest inline", (): void => {
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
    it("given a badge, when spans are collected, then its text, colour and source span are returned", (): void => {
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
