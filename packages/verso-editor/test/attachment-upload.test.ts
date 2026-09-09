import { describe, expect, it } from "vitest";
import { attachmentMarkdown, isInlineImage } from "../src/attachment-upload.js";

/** Builds a minimal File-like value for classification and upload tests. */
function fileLike(name: string, type = ""): File {
    return new File([new Uint8Array([1, 2, 3])], name, { type });
}

describe("inline-image classification", (): void => {
    it.each([
        ["cat.png", "image/png"],
        ["cat.JPG", "image/jpeg"],
        ["cat.jpeg", "image/jpeg"],
        ["cat.gif", "image/gif"],
        ["cat.webp", "image/webp"],
    ])("treats %s as an inline image", (name, type): void => {
        expect(isInlineImage(fileLike(name, type))).toBe(true);
    });

    it.each([
        ["diagram.svg", "image/svg+xml"],
        ["report.pdf", "application/pdf"],
        ["notes.txt", "text/plain"],
        ["archive.zip", "application/zip"],
    ])("treats %s as a download attachment", (name, type): void => {
        expect(isInlineImage(fileLike(name, type))).toBe(false);
    });

    it("given a name with no extension, when the file is classified, then its MIME type decides", (): void => {
        expect(isInlineImage(fileLike("clipboard", "image/png"))).toBe(true);
        expect(isInlineImage(fileLike("clipboard", "image/svg+xml"))).toBe(false);
    });
});

describe("attachment Markdown", (): void => {
    it("given an inline image, when its Markdown is built, then it is embedded with the filename as alt text", (): void => {
        expect(attachmentMarkdown(fileLike("cat.png", "image/png"), "/attachments/h/cat.png")).toBe(
            "![cat.png](/attachments/h/cat.png)",
        );
    });

    it("given a non-image attachment, when its Markdown is built, then it is linked with the filename as link text", (): void => {
        expect(attachmentMarkdown(fileLike("report.pdf", "application/pdf"), "/attachments/h/report.pdf")).toBe(
            "[report.pdf](/attachments/h/report.pdf)",
        );
    });
});
