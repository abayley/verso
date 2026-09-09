import { describe, expect, it } from "vitest";
import { imageShortTitles } from "../src/image-metadata.js";

describe("imageShortTitles", (): void => {
    it("given an image with alt text, when titles are collected, then the alt text is the short_title", (): void => {
        expect(imageShortTitles("![A Diagram](assets/diagram.png)")).toEqual([
            { localPath: "assets/diagram.png", shortTitle: "A Diagram" },
        ]);
    });

    it("given an image with empty alt text, when titles are collected, then the filename is used", (): void => {
        expect(imageShortTitles("![](assets/diagram.png)")).toEqual([
            { localPath: "assets/diagram.png", shortTitle: "diagram.png" },
        ]);
    });

    it("given alt text with surrounding whitespace, when titles are collected, then it is trimmed", (): void => {
        expect(imageShortTitles("![  Spaced  ](assets/a.png)")).toEqual([
            { localPath: "assets/a.png", shortTitle: "Spaced" },
        ]);
    });

    it("given an image carrying a title and a width attribute, when titles are collected, then both are ignored", (): void => {
        expect(imageShortTitles('![A](assets/a.png "tooltip"){width=300}')).toEqual([
            { localPath: "assets/a.png", shortTitle: "A" },
        ]);
    });

    it("given the same image twice, when titles are collected, then it is reported once, from its first occurrence", (): void => {
        const markdown = "![First](assets/a.png)\n\n![Second](assets/a.png)";

        expect(imageShortTitles(markdown)).toEqual([{ localPath: "assets/a.png", shortTitle: "First" }]);
    });

    it("given several distinct images, when titles are collected, then all are reported in order", (): void => {
        const markdown = "![One](assets/a.png)\n![Two](assets/b.png)";

        expect(imageShortTitles(markdown)).toEqual([
            { localPath: "assets/a.png", shortTitle: "One" },
            { localPath: "assets/b.png", shortTitle: "Two" },
        ]);
    });

    it("given external images and non-asset destinations, when titles are collected, then they are skipped", (): void => {
        const markdown = "![Remote](https://example.com/x.png)\n![Other](../shared/y.png)";

        expect(imageShortTitles(markdown)).toEqual([]);
    });
});
