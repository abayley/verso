import { describe, expect, it } from "vitest";
import { type ContentExtensionFor, createContentPipeline } from "../../src/Verso/Editor/content-extension.js";
import { parseMarkdownWithRemark } from "../../src/Verso/Editor/remark-adapter.js";

declare module "../../src/Verso/Editor/editor-model.js" {
    interface ContentExtensionPayloads {
        absent: { block: Record<string, never> };
        feature: { block: { marker: string } };
        first: { block: Record<string, never> };
        other: { block: Record<string, never> };
        owner: { block: Record<string, never> };
        second: { block: Record<string, never> };
    }
}

describe("createContentPipeline", (): void => {
    it("given no feature extensions, when base Markdown is parsed and serialised, then it is preserved", (): void => {
        const pipeline = createContentPipeline([]);
        const markdown = "# Heading\n\nParagraph with **strong** text.";

        expect(pipeline.documentToMarkdown(parseMarkdownWithRemark(markdown, pipeline))).toBe(markdown);
    });

    it("given ordered feature extensions, when a node is recognised, then supplied order precedes the base", (): void => {
        const visited: string[] = [];
        const decliningExtension: ContentExtensionFor<"first"> = {
            blockFromMdast: () => {
                visited.push("first");

                return null;
            },
            name: "first",
        };
        const recognisingExtension: ContentExtensionFor<"second"> = {
            blockFromMdast: () => {
                visited.push("second");

                return { children: [], data: {} };
            },
            name: "second",
        };
        const pipeline = createContentPipeline([decliningExtension, recognisingExtension]);

        expect(pipeline.documentFromMdast([{ children: [], type: "paragraph" }]).blocks).toEqual([
            { children: [], data: {}, extension: "second", type: "custom" },
        ]);
        expect(visited).toEqual(["first", "second"]);
    });

    it("given duplicate feature names, when a pipeline is constructed, then it rejects the duplicate", (): void => {
        const extension: ContentExtensionFor<"first"> = { name: "first" };

        expect((): void => {
            createContentPipeline([extension, extension]);
        }).toThrow("Duplicate content extension name: first");
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
        const feature: ContentExtensionFor<"feature"> = {
            blockFromMdast: (node) => (node.type === "thematicBreak" ? { data: { marker: "feature" } } : null),
            blockToMarkdown: (data) => data.marker,
            name: "feature",
        };
        const baseOnly = createContentPipeline([]);
        const withFeature = createContentPipeline([feature]);
        const thematicBreak = [{ type: "thematicBreak" }] as const;

        expect(withFeature.documentFromMdast([...thematicBreak]).blocks[0]).toMatchObject({ extension: "feature" });
        expect(baseOnly.documentFromMdast([...thematicBreak]).blocks[0]).toEqual({ type: "horizontalRule" });
        expect(withFeature.documentToMarkdown(withFeature.documentFromMdast([...thematicBreak]))).toBe("feature");
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
