import { describe, expect, it } from "vitest";
import { parseMarkdown } from "../../src/TestApp/Editor/markdown-parse.js";
import { documentFromElements, documentToMarkdown } from "../../src/TestApp/Editor/markdown-serialise.js";

describe("reference link parsing", (): void => {
    it("given a full reference and its definition, when parsed, then it becomes a custom reference-link inline and a definition block", (): void => {
        expect(parseMarkdown(["See [the docs][d] now.", "", "[d]: https://example.com"].join("\n"))).toEqual({
            blocks: [
                {
                    children: [
                        { text: "See ", type: "text" },
                        {
                            children: [{ text: "the docs", type: "text" }],
                            data: { label: "d", referenceType: "full", title: null, url: "https://example.com" },
                            extension: "reference-link",
                            type: "custom",
                        },
                        { text: " now.", type: "text" },
                    ],
                    type: "paragraph",
                },
                {
                    data: { label: "d", title: null, url: "https://example.com" },
                    extension: "reference-link",
                    type: "custom",
                },
            ],
        });
    });

    it.each([
        ["full", "Read [the docs][d].", "full"],
        ["collapsed", "Read [the docs][].", "collapsed"],
        ["shortcut", "Read [the docs].", "shortcut"],
    ])("given a %s reference, when parsed, then its referenceType is carried", (_name, reference, referenceType): void => {
        const document = parseMarkdown(
            [reference, "", "[the docs]: https://example.com", "[d]: https://example.com"].join("\n"),
        );
        const inline = (document.blocks[0] as { children: { data?: { referenceType?: string } }[] }).children[1];

        expect(inline).toMatchObject({ data: { referenceType }, extension: "reference-link", type: "custom" });
    });

    it("given a definition with a title, when parsed, then the title is carried", (): void => {
        const document = parseMarkdown(['[d]: https://example.com "Docs"'].join("\n"));

        expect(document.blocks[0]).toEqual({
            data: { label: "d", title: "Docs", url: "https://example.com" },
            extension: "reference-link",
            type: "custom",
        });
    });
});

describe("reference link Markdown round-trip", (): void => {
    it.each([
        ["full", "See [the docs][d].\n\n[d]: https://example.com"],
        ["collapsed", "See [the docs][].\n\n[the docs]: https://example.com"],
        ["shortcut", "See [the docs].\n\n[the docs]: https://example.com"],
        ["titled", 'See [the docs][d].\n\n[d]: https://example.com "Docs"'],
    ])("given a %s reference, when parsed and serialised, then the source round-trips", (_name, markdown): void => {
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});

describe("reference link DOM serialisation", (): void => {
    it("given a reference-link anchor element, when serialised, then it becomes a reference link", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<p>See <a class="markdown-reference-link" data-reference-label="d" data-reference-type="full" href="https://example.com">the docs</a>.</p>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe("See [the docs][d].");
    });

    it("given a definition element, when serialised, then it becomes a [label]: url definition", (): void => {
        const root = document.createElement("div");
        root.innerHTML =
            '<div class="markdown-reference-def" data-reference-label="d" data-reference-url="https://example.com" data-reference-title="Docs"></div>';

        expect(documentToMarkdown(documentFromElements(root.children))).toBe('[d]: https://example.com "Docs"');
    });
});
