import { describe, expect, it } from "vitest";
import { commonContentPipeline } from "../../src/Verso/Editor/register-extensions.js";
import { parseMarkdownWithRemark } from "../../src/Verso/Editor/remark-adapter.js";

const parseMarkdown = (markdown: string) => parseMarkdownWithRemark(markdown, commonContentPipeline);
const { documentFromElements, documentToMarkdown } = commonContentPipeline;

describe("commonContentPipeline DOM conversion", (): void => {
    it("serialises supported DOM blocks into an editor document", (): void => {
        const root = document.createElement("div");

        root.innerHTML = [
            "<h1>Heading</h1>",
            '<p>Paragraph with <strong>strong</strong>, <em>emphasis</em>, <code>code</code>, <del>strike</del>, and <a href="/target">link</a>.</p>',
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
                        { text: ", ", type: "text" },
                        { children: [{ text: "strike", type: "text" }], type: "strikethrough" },
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
                    items: [
                        {
                            blocks: [
                                {
                                    children: [{ text: "first", type: "text" }],
                                    type: "paragraph",
                                },
                            ],
                        },
                        {
                            blocks: [
                                {
                                    children: [{ text: "second", type: "text" }],
                                    type: "paragraph",
                                },
                            ],
                        },
                    ],
                    ordered: false,
                    type: "list",
                },
                {
                    items: [
                        {
                            blocks: [
                                {
                                    children: [{ text: "ordered", type: "text" }],
                                    type: "paragraph",
                                },
                            ],
                        },
                        {
                            blocks: [
                                {
                                    children: [{ text: "list", type: "text" }],
                                    type: "paragraph",
                                },
                            ],
                        },
                    ],
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

    it("serialises heading elements of every level into editor headings", (): void => {
        const root = document.createElement("div");
        root.innerHTML = ["<h4>Four</h4>", "<h5>Five</h5>", "<h6>Six</h6>"].join("");

        expect(documentFromElements(root.children)).toEqual({
            blocks: [
                { children: [{ text: "Four", type: "text" }], level: 4, type: "heading" },
                { children: [{ text: "Five", type: "text" }], level: 5, type: "heading" },
                { children: [{ text: "Six", type: "text" }], level: 6, type: "heading" },
            ],
        });
    });

    it("given headings of every level, when round-tripped, then the heading depth is preserved", (): void => {
        const markdown = ["#### Four", "", "##### Five", "", "###### Six"].join("\n");

        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
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

    it("serialises line break elements into editor break inline nodes", (): void => {
        const root = document.createElement("div");
        root.innerHTML = "<p>First line<br>second line.</p>";

        expect(documentFromElements(root.children)).toEqual({
            blocks: [
                {
                    children: [
                        { text: "First line", type: "text" },
                        { type: "break" },
                        { text: "second line.", type: "text" },
                    ],
                    type: "paragraph",
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
                        items: [
                            {
                                blocks: [
                                    {
                                        children: [{ text: "first", type: "text" }],
                                        type: "paragraph",
                                    },
                                ],
                            },
                            {
                                blocks: [
                                    {
                                        children: [{ text: "second", type: "text" }],
                                        type: "paragraph",
                                    },
                                ],
                            },
                        ],
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

    it("given a list item containing a blockquote, when serialised, then continuation quote lines stay inside the list item", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        items: [
                            {
                                blocks: [
                                    {
                                        blocks: [
                                            {
                                                children: [{ text: "blockquote heading 1", type: "text" }],
                                                level: 1,
                                                type: "heading",
                                            },
                                            {
                                                children: [{ text: "paragraph 1", type: "text" }],
                                                type: "paragraph",
                                            },
                                        ],
                                        type: "blockquote",
                                    },
                                ],
                            },
                        ],
                        ordered: false,
                        type: "list",
                    },
                ],
            }),
        ).toBe(["- > # blockquote heading 1", "  >", "  > paragraph 1"].join("\n"));
    });

    it("given a blockquote containing a spread ordered list, when serialised, then quoted list spacing is preserved", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        blocks: [
                            {
                                items: [
                                    {
                                        blocks: [
                                            {
                                                children: [{ text: "item 1", type: "text" }],
                                                type: "paragraph",
                                            },
                                        ],
                                    },
                                    {
                                        blocks: [
                                            {
                                                children: [{ text: "item 2", type: "text" }],
                                                type: "paragraph",
                                            },
                                            {
                                                language: "shell",
                                                text: "ls -al\nps -ef",
                                                type: "codeBlock",
                                            },
                                        ],
                                    },
                                    {
                                        blocks: [
                                            {
                                                children: [{ text: "item 3", type: "text" }],
                                                type: "paragraph",
                                            },
                                        ],
                                    },
                                ],
                                ordered: true,
                                type: "list",
                            },
                        ],
                        type: "blockquote",
                    },
                ],
            }),
        ).toBe(
            [
                "> 1. item 1",
                "> 2. item 2",
                ">    ",
                ">    ```shell",
                ">    ls -al",
                ">    ps -ef",
                ">    ```",
                ">",
                "> 3. item 3",
            ].join("\n"),
        );
    });

    it("serialises break inline nodes to Markdown hard breaks", (): void => {
        expect(
            documentToMarkdown({
                blocks: [
                    {
                        children: [
                            { text: "First line", type: "text" },
                            { type: "break" },
                            { text: "second line.", type: "text" },
                        ],
                        type: "paragraph",
                    },
                ],
            }),
        ).toBe(["First line\\", "second line."].join("\n"));
    });
});

describe("Markdown round-trip", (): void => {
    it.each([
        ["a MkDocs Material icon shortcode", ":material-book-open-page-variant: Reference material"],
        ["a shortcode among text", "See :material-cog: settings and :material-home: home."],
    ])("given %s, when parsed and serialised, then it round-trips verbatim as text", (_name, markdown): void => {
        // Icon shortcodes are not CommonMark; the editor treats them as plain text and preserves them.
        expect(documentToMarkdown(parseMarkdown(markdown))).toBe(markdown);
    });
});
