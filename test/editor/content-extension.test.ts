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

    it("given a custom node, when serialised, then only its named extension handles it", (): void => {
        const visited: string[] = [];
        const pipeline = createContentPipeline([
            {
                blockToMarkdown: () => {
                    visited.push("other");

                    return "wrong";
                },
                name: "other",
            },
            {
                blockToMarkdown: () => {
                    visited.push("owner");

                    return "owned";
                },
                name: "owner",
            },
        ]);

        expect(
            pipeline.documentToMarkdown({
                blocks: [{ data: {}, extension: "owner", type: "custom" }],
            }),
        ).toBe("owned");
        expect(visited).toEqual(["owner"]);
    });

    it("given pipelines with different feature sets, when both run, then neither changes the other", (): void => {
        const feature: ContentExtension = {
            blockFromMdast: (node) =>
                node.type === "thematicBreak"
                    ? { data: { marker: "feature" }, extension: "feature", type: "custom" }
                    : null,
            name: "feature",
        };
        const baseOnly = createContentPipeline([]);
        const withFeature = createContentPipeline([feature]);
        const thematicBreak = [{ type: "thematicBreak" }] as const;

        expect(withFeature.documentFromMdast([...thematicBreak]).blocks[0]).toMatchObject({ extension: "feature" });
        expect(baseOnly.documentFromMdast([...thematicBreak]).blocks[0]).toEqual({ type: "horizontalRule" });
    });

    it("given a custom node whose extension is absent, when serialised, then it produces the fail-soft empty result", (): void => {
        const pipeline = createContentPipeline([]);

        expect(
            pipeline.documentToMarkdown({
                blocks: [{ data: {}, extension: "absent", type: "custom" }],
            }),
        ).toBe("");
    });
});
