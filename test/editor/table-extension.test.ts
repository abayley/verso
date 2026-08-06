import { describe, expect, it } from "vitest";
import { commonContentPipeline } from "../../src/Verso/Editor/register-extensions.js";
import { parseMarkdownWithRemark } from "../../src/Verso/Editor/remark-adapter.js";

const parseMarkdown = (markdown: string) => parseMarkdownWithRemark(markdown, commonContentPipeline);
const { documentFromElements, documentToMarkdown } = commonContentPipeline;

const TWO_COLUMN = ["| H1 | H2 |", "| :--- | ---: |", "| a | **b** |"].join("\n");

describe("table parsing", (): void => {
    it("given a GFM table, when parsed, then it becomes a custom table block with alignment, header, and rows", (): void => {
        expect(parseMarkdown(TWO_COLUMN)).toEqual({
            blocks: [
                {
                    data: {
                        align: ["left", "right"],
                        header: [[{ text: "H1", type: "text" }], [{ text: "H2", type: "text" }]],
                        rows: [
                            [
                                [{ text: "a", type: "text" }],
                                [{ children: [{ text: "b", type: "text" }], type: "strong" }],
                            ],
                        ],
                    },
                    extension: "table",
                    type: "custom",
                },
            ],
        });
    });

    it("given each alignment marker, when parsed, then the column alignment is captured", (): void => {
        const document = parseMarkdown(
            ["| a | b | c | d |", "| :-- | :-: | --: | --- |", "| 1 | 2 | 3 | 4 |"].join("\n"),
        );
        const block = document.blocks[0];

        expect(block).toMatchObject({ data: { align: ["left", "center", "right", null] } });
    });
});

describe("table Markdown round-trip", (): void => {
    it("given a canonical GFM table, when parsed and serialised, then it round-trips", (): void => {
        expect(documentToMarkdown(parseMarkdown(TWO_COLUMN))).toBe(TWO_COLUMN);
    });

    it("given mixed delimiter widths, when parsed and serialised, then the delimiter row normalises", (): void => {
        const messy = ["| a | b | c |", "| :----- | :----: | -----: |", "| 1 | 2 | 3 |"].join("\n");

        expect(documentToMarkdown(parseMarkdown(messy))).toBe(
            ["| a | b | c |", "| :--- | :---: | ---: |", "| 1 | 2 | 3 |"].join("\n"),
        );
    });

    it("given a cell containing a pipe, when serialised, then the pipe is escaped", (): void => {
        const block = {
            data: {
                align: [null],
                header: [[{ text: "h", type: "text" as const }]],
                rows: [[[{ text: "a | b", type: "text" as const }]]],
            },
            extension: "table" as const,
            type: "custom" as const,
        };

        expect(documentToMarkdown({ blocks: [block] })).toBe(["| h |", "| --- |", "| a \\| b |"].join("\n"));
    });
});

describe("table DOM serialisation", (): void => {
    it("given a rendered table element, when serialised, then it becomes a GFM table", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            "<table>" +
            '<thead><tr><th style="text-align: left">H1</th><th style="text-align: right">H2</th></tr></thead>' +
            '<tbody><tr><td style="text-align: left">a</td><td style="text-align: right"><strong>b</strong></td></tr></tbody>' +
            "</table>";

        expect(documentToMarkdown(documentFromElements(root.children))).toBe(TWO_COLUMN);
    });

    it("given a table wrapped in a div (as Tiptap renders it), when serialised, then it becomes a GFM table", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<div class="tableWrapper"><table><tbody><tr><th>H</th></tr><tr><td>v</td></tr></tbody></table></div>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe(["| H |", "| --- |", "| v |"].join("\n"));
    });

    it("given a table whose header cells are in the body, when serialised, then the first row is the header", (): void => {
        const root = document.createElement("div");
        root.innerHTML = "<table><tbody><tr><th>H</th></tr><tr><td>v</td></tr></tbody></table>";

        expect(documentToMarkdown(documentFromElements(root.children))).toBe(["| H |", "| --- |", "| v |"].join("\n"));
    });
});
