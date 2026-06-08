import { describe, expect, it } from "vitest";
import { parseMarkdown } from "../../src/TestApp/Editor/markdown-parse.js";

describe("parseMarkdown", (): void => {
    it("parses supported block and inline nodes into an editor document", (): void => {
        const markdown = [
            "# Heading",
            "",
            "Paragraph with **strong**, *emphasis*, `code`, and [link](/target).",
            "",
            "- first",
            "- second",
            "",
            "1. ordered",
            "2. list",
        ].join("\n");

        expect(parseMarkdown(markdown)).toEqual({
            blocks: [
                {
                    level: 1,
                    children: [{ text: "Heading", type: "text" }],
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

    it("given raw HTML, when parsed, then it rejects the unsupported node", (): void => {
        expect((): void => {
            parseMarkdown("<script>alert(1)</script>");
        }).toThrow("Unsupported Markdown node for editor subset: html");
    });

    it("parses horizontal rules into editor blocks", (): void => {
        expect(parseMarkdown("---")).toEqual({
            blocks: [
                {
                    type: "horizontalRule",
                },
            ],
        });
    });

    it("given fenced code Markdown, when parsed, then it returns a code block", (): void => {
        expect(parseMarkdown(["```typescript", "const value = 1;", "```"].join("\n"))).toEqual({
            blocks: [
                {
                    language: "typescript",
                    text: "const value = 1;",
                    type: "codeBlock",
                },
            ],
        });
    });

    it("given blockquote Markdown, when parsed, then it returns a blockquote block", (): void => {
        expect(parseMarkdown("> Quoted **text**.")).toEqual({
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

    it("given a hard line break, when parsed, then it returns a break inline node", (): void => {
        expect(parseMarkdown(["First line\\", "second line."].join("\n"))).toEqual({
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
