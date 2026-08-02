import { describe, expect, it } from "vitest";
import { activeSections, documentHeadings } from "../../src/Verso/Editor/table-of-contents.js";

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

describe("activeSections", (): void => {
    // A four-entry document: H1 Title, H2 One, H3 Detail, H2 Two, with the headings 100px apart. The band
    // stands for the visible document: below the sticky top bar, above the fold.
    const levels = [1, 2, 3, 2];
    const tops = [0, 100, 200, 300];

    it("given the viewport over one section, when marked, then that entry and its ancestors are active", (): void => {
        expect(activeSections(levels, tops, 210, 290)).toEqual([true, true, true, false]);
    });

    it("given a section scrolled past its own heading, when marked, then it stays active", (): void => {
        // Deep inside one long section: nothing on screen but its body, its own heading long scrolled past
        // and the next section still far below.
        expect(activeSections([1, 2, 2], [0, 100, 5000], 400, 600)).toEqual([true, true, false]);
    });

    it("given the viewport spanning a boundary, when marked, then both sections are active", (): void => {
        expect(activeSections(levels, tops, 250, 350)).toEqual([true, true, true, true]);
    });

    it("given the viewport above the first heading, when marked, then nothing is active", (): void => {
        expect(activeSections(levels, tops, -400, -100)).toEqual([false, false, false, false]);
    });

    it("given a sibling subsection above the fold, when marked, then it is not active but its parent is", (): void => {
        expect(activeSections(levels, tops, 210, 290)[1]).toBe(true);
        expect(activeSections(levels, tops, 210, 290)[3]).toBe(false);
    });

    it("given a heading with no measurement, when marked, then it is not active", (): void => {
        expect(activeSections(levels, [0, 100], 0, 1000)).toEqual([true, true, false, false]);
    });
});
