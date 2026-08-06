import { describe, expect, it } from "vitest";
import { type ContentExtension, createContentPipeline } from "../../src/Verso/Editor/content-extension.js";
import { parseMarkdownWithRemark } from "../../src/Verso/Editor/remark-adapter.js";

describe("createContentPipeline", (): void => {
    it("given no feature extensions, when base Markdown is parsed and serialised, then it is preserved", (): void => {
        const pipeline = createContentPipeline([]);
        const markdown = "# Heading\n\nParagraph with **strong** text.";

        expect(pipeline.documentToMarkdown(parseMarkdownWithRemark(markdown, pipeline))).toBe(markdown);
    });

    it("given ordered feature extensions, when a node is recognised, then supplied order precedes the base", (): void => {
        const visited: string[] = [];
        const decliningExtension: ContentExtension = {
            blockFromMdast: () => {
                visited.push("first");

                return null;
            },
            name: "first",
        };
        const recognisingExtension: ContentExtension = {
            blockFromMdast: () => {
                visited.push("second");

                return { children: [], data: {}, extension: "second", type: "custom" };
            },
            name: "second",
        };
        const pipeline = createContentPipeline([decliningExtension, recognisingExtension]);

        expect(pipeline.documentFromMdast([{ children: [], type: "paragraph" }]).blocks).toEqual([
            { children: [], data: {}, extension: "second", type: "custom" },
        ]);
        expect(visited).toEqual(["first", "second"]);
    });

    it("given a feature named base, when a pipeline is constructed, then it rejects replacement of the base", (): void => {
        expect((): void => {
            createContentPipeline([{ name: "base" }]);
        }).toThrow("Duplicate content extension name: base");
    });
});
