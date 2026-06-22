import { describe, expect, it } from "vitest";
import { documentHeadings } from "../../src/TestApp/Editor/table-of-contents.js";

describe("documentHeadings", (): void => {
    it("given ATX headings, when parsed, then it returns them in order with levels", (): void => {
        const markdown = ["# Title", "", "## Section one", "", "### Detail", "", "## Section two"].join("\n");

        expect(documentHeadings(markdown)).toEqual([
            { level: 1, text: "Title" },
            { level: 2, text: "Section one" },
            { level: 3, text: "Detail" },
            { level: 2, text: "Section two" },
        ]);
    });

    it("given a hash without a following space, when parsed, then it is not a heading", (): void => {
        expect(documentHeadings("#nothashtag\n# Real")).toEqual([{ level: 1, text: "Real" }]);
    });

    it("given seven hashes, when parsed, then it is not a heading (levels stop at six)", (): void => {
        expect(documentHeadings("####### Too deep\n###### Six")).toEqual([{ level: 6, text: "Six" }]);
    });

    it("given a hash line inside a fenced code block, when parsed, then it is ignored", (): void => {
        const markdown = ["# Real", "", "```sh", "# a shell comment", "## not a heading", "```", "", "## After"].join(
            "\n",
        );

        expect(documentHeadings(markdown)).toEqual([
            { level: 1, text: "Real" },
            { level: 2, text: "After" },
        ]);
    });

    it("given a tilde-fenced block, when parsed, then hash lines inside it are ignored", (): void => {
        expect(documentHeadings(["~~~", "# inside", "~~~", "# outside"].join("\n"))).toEqual([
            { level: 1, text: "outside" },
        ]);
    });

    it("given a closing hash sequence, when parsed, then it is stripped from the text", (): void => {
        expect(documentHeadings("## Centred ##")).toEqual([{ level: 2, text: "Centred" }]);
    });

    it("given inline markup in a heading, when parsed, then markers are stripped and links unwrapped", (): void => {
        expect(documentHeadings("## **Bold** and `code` and [a link](http://x)")).toEqual([
            { level: 2, text: "Bold and code and a link" },
        ]);
    });

    it("given an indented hash (inside a list or collapsible body), when parsed, then it is not listed", (): void => {
        expect(documentHeadings("# Top\n\n    # indented")).toEqual([{ level: 1, text: "Top" }]);
    });

    it("given Markdown with no headings, when parsed, then the list is empty", (): void => {
        expect(documentHeadings("Just a paragraph.\n\nAnother one.")).toEqual([]);
    });
});
