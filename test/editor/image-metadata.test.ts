import { describe, expect, it } from "vitest";
import { imageShortTitles } from "../../src/Verso/Editor/image-metadata.js";

describe("imageShortTitles", (): void => {
    it("uses the alt text as the short_title", (): void => {
        expect(imageShortTitles("![A Diagram](assets/diagram.png)")).toEqual([
            { localPath: "assets/diagram.png", shortTitle: "A Diagram" },
        ]);
    });

    it("falls back to the filename when the alt text is empty", (): void => {
        expect(imageShortTitles("![](assets/diagram.png)")).toEqual([
            { localPath: "assets/diagram.png", shortTitle: "diagram.png" },
        ]);
    });

    it("trims surrounding whitespace from the alt text", (): void => {
        expect(imageShortTitles("![  Spaced  ](assets/a.png)")).toEqual([
            { localPath: "assets/a.png", shortTitle: "Spaced" },
        ]);
    });

    it("ignores a title and a trailing width attribute", (): void => {
        expect(imageShortTitles('![A](assets/a.png "tooltip"){width=300}')).toEqual([
            { localPath: "assets/a.png", shortTitle: "A" },
        ]);
    });

    it("reports each page-relative image once, keeping the first occurrence", (): void => {
        const markdown = "![First](assets/a.png)\n\n![Second](assets/a.png)";

        expect(imageShortTitles(markdown)).toEqual([{ localPath: "assets/a.png", shortTitle: "First" }]);
    });

    it("reports multiple distinct images in order", (): void => {
        const markdown = "![One](assets/a.png)\n![Two](assets/b.png)";

        expect(imageShortTitles(markdown)).toEqual([
            { localPath: "assets/a.png", shortTitle: "One" },
            { localPath: "assets/b.png", shortTitle: "Two" },
        ]);
    });

    it("skips external images and non-asset destinations", (): void => {
        const markdown = "![Remote](https://example.com/x.png)\n![Other](../shared/y.png)";

        expect(imageShortTitles(markdown)).toEqual([]);
    });
});
