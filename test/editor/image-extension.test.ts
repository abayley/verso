import { describe, expect, it } from "vitest";
import { parseMarkdown } from "../../src/Verso/Editor/markdown-parse.js";
import { documentFromElements, documentToMarkdown } from "../../src/Verso/Editor/markdown-serialise.js";

describe("image parsing", (): void => {
    it("given an image, when parsed, then it becomes a custom image inline", (): void => {
        expect(parseMarkdown("![a cat](/cat.png)")).toEqual({
            blocks: [
                {
                    children: [
                        {
                            data: { alt: "a cat", src: "/cat.png", title: null, width: null },
                            extension: "image",
                            type: "custom",
                        },
                    ],
                    type: "paragraph",
                },
            ],
        });
    });

    it("given an image with a title, when parsed, then the title is carried", (): void => {
        const document = parseMarkdown('![a cat](/cat.png "Tabby")');
        const inline = (document.blocks[0] as { children: unknown[] }).children[0];

        expect(inline).toEqual({
            data: { alt: "a cat", src: "/cat.png", title: "Tabby", width: null },
            extension: "image",
            type: "custom",
        });
    });

    it("given an image with empty alt, when parsed, then alt is empty", (): void => {
        const document = parseMarkdown("![](/cat.png)");
        const inline = (document.blocks[0] as { children: { data?: { alt?: string } }[] }).children[0];

        expect(inline).toMatchObject({ data: { alt: "" } });
    });
});

describe("image width attribute", (): void => {
    it("given an image with a {width=N} attribute, when parsed, then the width is carried", (): void => {
        const document = parseMarkdown("![a cat](/cat.png){width=300}");
        const inline = (document.blocks[0] as { children: unknown[] }).children[0];

        expect(inline).toEqual({
            data: { alt: "a cat", src: "/cat.png", title: null, width: 300 },
            extension: "image",
            type: "custom",
        });
    });

    it("given a width alongside a title, when parsed, then both are carried", (): void => {
        const document = parseMarkdown('![a cat](/cat.png "Tabby"){width=300}');
        const inline = (document.blocks[0] as { children: unknown[] }).children[0];

        expect(inline).toEqual({
            data: { alt: "a cat", src: "/cat.png", title: "Tabby", width: 300 },
            extension: "image",
            type: "custom",
        });
    });

    it.each([
        ["plain width", "![a cat](/cat.png){width=300}"],
        ["titled width", '![a cat](/cat.png "Tabby"){width=300}'],
    ])("given a %s image, when parsed and serialised, then the source round-trips", (_name, markdown): void => {
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });

    it("given an img with a width attribute, when serialised from the DOM, then {width=N} is emitted", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<p><img src="/cat.png" alt="a cat" width="300"></p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("![a cat](/cat.png){width=300}");
    });
});

describe("image Markdown round-trip", (): void => {
    it.each([
        ["plain", "![a cat](/cat.png)"],
        ["titled", '![a cat](/cat.png "Tabby")'],
        ["empty alt", "![](/cat.png)"],
        ["external", "![a cat](https://example.com/cat.png)"],
    ])("given a %s image, when parsed and serialised, then the source round-trips", (_name, markdown): void => {
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("image DOM serialisation", (): void => {
    it("given an img element, when serialised, then it becomes an image", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<p><img src="/cat.png" alt="a cat" title="Tabby"></p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe('![a cat](/cat.png "Tabby")');
    });

    it("given an img element without a title, when serialised, then no title is emitted", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<p><img src="/cat.png" alt="a cat"></p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("![a cat](/cat.png)");
    });

    it("given a block-level img element, when serialised, then it becomes a standalone image", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<img src="/cat.png" alt="a cat" title="Tabby">';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe('![a cat](/cat.png "Tabby")');
    });

    it("given ProseMirror's separator img beside an image, when serialised, then the separator is ignored", (): void => {
        const root = document.createElement("div");
        // ProseMirror inserts <img class="ProseMirror-separator"> next to an inline atom for cursor
        // placement; it is an editor artifact, not content, and must not serialise as a stray image.
        root.innerHTML = '<p><img src="/cat.png" alt="a cat"><img class="ProseMirror-separator" alt=""></p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("![a cat](/cat.png)");
    });

    it.each([
        ["a src-less img inside a paragraph", "<p>text<img></p>", "text"],
        ["a src-less img alone in a paragraph", "<p><img></p>", ""],
        ["a src-less img at block level", "<img>", ""],
        ["a block-level separator img", '<img class="ProseMirror-separator">', ""],
    ])("given %s (a deletion/cursor artifact), when serialised, then no stray image is emitted", (_name, html, expected): void => {
        const root = document.createElement("div");
        root.innerHTML = html;

        expect(documentToMarkdown(documentFromElements(root.children))).toBe(expected);
    });
});
