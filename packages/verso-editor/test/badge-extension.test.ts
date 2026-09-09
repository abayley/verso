import { describe, expect, it } from "vitest";
import { badgeExtension } from "../src/badge-extension.js";
import { createContentPipeline } from "../src/content-extension.js";
import { parseMarkdownWithRemark } from "../src/remark-adapter.js";

const pipeline = createContentPipeline([badgeExtension]);
const parseMarkdown = (markdown: string) => parseMarkdownWithRemark(markdown, pipeline);
const { documentFromElements, documentToMarkdown } = pipeline;

describe("badge parsing", (): void => {
    it("given an inline code span with a badge attribute list, when parsed, then it becomes a badge inline", (): void => {
        const document = parseMarkdown("`TODO`{.badge.yellow}");

        expect((document.blocks[0] as { children: unknown[] }).children).toEqual([
            { data: { colour: "yellow", text: "TODO" }, extension: "badge", type: "custom" },
        ]);
    });

    it("given a spaced attribute list, when parsed, then it is still recognised", (): void => {
        const document = parseMarkdown("`X`{ .badge .red }");

        expect((document.blocks[0] as { children: unknown[] }).children).toEqual([
            { data: { colour: "red", text: "X" }, extension: "badge", type: "custom" },
        ]);
    });

    it.each([
        ["a space before the brace", "`X` {.badge.red}"],
        ["a missing colour", "`X`{.badge}"],
        ["a colour-only list", "`X`{.red}"],
        ["extra classes", "`X`{.badge.red.bold}"],
    ])("given %s, when parsed and serialised, then it stays literal (not a badge)", (_name, markdown): void => {
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("badge round-trip", (): void => {
    it.each([
        ["yellow", "`TODO`{.badge.yellow}"],
        ["red", "`UNREACHABLE`{.badge.red}"],
        ["an arbitrary colour", "`X`{.badge.cornflowerblue}"],
        ["text containing a backtick", "``a`b``{.badge.green}"],
    ])("given %s, when parsed and serialised, then it round-trips canonically", (_name, markdown): void => {
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("badge DOM serialisation", (): void => {
    it("given a rendered badge span, when serialised, then the canonical Markdown is emitted", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<p><span class="badge" data-badge-colour="red">UNREACHABLE</span></p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("`UNREACHABLE`{.badge.red}");
    });
});
