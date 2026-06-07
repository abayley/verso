import { describe, expect, it } from "vitest";
import { documentFromElements, documentToMarkdown } from "../../src/TestApp/Editor/markdown-serialise.js";

describe("documentFromElements", (): void => {
    it("serialises supported DOM blocks into an editor document", (): void => {
        const root = document.createElement("div");

        root.innerHTML = [
            "<h1>Heading</h1>",
            '<p>Paragraph with <strong>strong</strong>, <em>emphasis</em>, <code>code</code>, and <a href="/target">link</a>.</p>',
            "<ul><li>first</li><li>second</li></ul>",
            "<ol><li>ordered</li><li>list</li></ol>",
        ].join("");

        expect(documentFromElements(root.children)).toEqual({
            blocks: [
                {
                    children: [{ text: "Heading", type: "text" }],
                    level: 1,
                    type: "heading",
                },
                {
                    children: [
                        { text: "Paragraph with ", type: "text" },
                        { children: [{ text: "strong", type: "text" }], type: "strong" },
                        { text: ", ", type: "text" },
                        { children: [{ text: "emphasis", type: "text" }], type: "emphasis" },
                        { text: ", ", type: "text" },
                        { text: "code", type: "code" },
                        { text: ", and ", type: "text" },
                        {
                            children: [{ text: "link", type: "text" }],
                            type: "link",
                            url: "/target",
                        },
                        { text: ".", type: "text" },
                    ],
                    type: "paragraph",
                },
                {
                    items: [[{ text: "first", type: "text" }], [{ text: "second", type: "text" }]],
                    ordered: false,
                    type: "list",
                },
                {
                    items: [[{ text: "ordered", type: "text" }], [{ text: "list", type: "text" }]],
                    ordered: true,
                    type: "list",
                },
            ],
        });
    });

    it("serialises horizontal-rule elements into editor blocks", (): void => {
        const root = document.createElement("div");
        root.innerHTML = "<hr>";

        expect(documentFromElements(root.children)).toEqual({
            blocks: [
                {
                    type: "horizontalRule",
                },
            ],
        });
    });

    it("serialises preformatted code elements into editor code blocks", (): void => {
        const root = document.createElement("div");
        root.innerHTML = '<pre><code class="language-typescript">const value = 1;</code></pre>';

        expect(documentFromElements(root.children)).toEqual({
            blocks: [
                {
                    language: "typescript",
                    text: "const value = 1;",
                    type: "codeBlock",
                },
            ],
        });
    });

    it("serialises blockquote elements into editor blockquote blocks", (): void => {
        const root = document.createElement("div");
        root.innerHTML = "<blockquote><p>Quoted <strong>text</strong>.</p></blockquote>";

        expect(documentFromElements(root.children)).toEqual({
            blocks: [
                {
                    blocks: [
                        {
                            children: [
                                { text: "Quoted ", type: "text" },
                                { children: [{ text: "text", type: "text" }], type: "strong" },
                                { text: ".", type: "text" },
                            ],
                            type: "paragraph",
                        },
                    ],
                    type: "blockquote",
                },
            ],
        });
    });
});

describe("documentToMarkdown", (): void => {
    it("serialises an editor document to Markdown", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        children: [{ text: "Heading", type: "text" }],
                        level: 1,
                        type: "heading",
                    },
                    {
                        children: [
                            { text: "Paragraph with ", type: "text" },
                            { children: [{ text: "strong", type: "text" }], type: "strong" },
                            { text: ", ", type: "text" },
                            {
                                children: [{ text: "link", type: "text" }],
                                type: "link",
                                url: "/target",
                            },
                            { text: ".", type: "text" },
                        ],
                        type: "paragraph",
                    },
                    {
                        items: [[{ text: "first", type: "text" }], [{ text: "second", type: "text" }]],
                        ordered: false,
                        type: "list",
                    },
                ],
            }),
        ).toBe("# Heading\n\nParagraph with **strong**, [link](/target).\n\n- first\n- second");
    });

    it("serialises horizontal-rule blocks to Markdown", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        type: "horizontalRule",
                    },
                ],
            }),
        ).toBe("---");
    });

    it("serialises code blocks to fenced Markdown", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        language: "typescript",
                        text: "const value = 1;",
                        type: "codeBlock",
                    },
                ],
            }),
        ).toBe(["```typescript", "const value = 1;", "```"].join("\n"));
    });

    it("serialises blockquote blocks to quoted Markdown", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        blocks: [
                            {
                                children: [
                                    { text: "Quoted ", type: "text" },
                                    { children: [{ text: "text", type: "text" }], type: "strong" },
                                    { text: ".", type: "text" },
                                ],
                                type: "paragraph",
                            },
                        ],
                        type: "blockquote",
                    },
                ],
            }),
        ).toBe("> Quoted **text**.");
    });
});
