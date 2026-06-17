import { afterEach, describe, expect, it, vi } from "vitest";
import { attachmentMarkdown, isInlineImage, uploadAttachment } from "../../src/TestApp/Editor/attachment-upload.js";

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

    it("falls back to the MIME type when the name has no extension", (): void => {
        expect(isInlineImage(fileLike("clipboard", "image/png"))).toBe(true);
        expect(isInlineImage(fileLike("clipboard", "image/svg+xml"))).toBe(false);
    });
});

describe("attachment Markdown", (): void => {
    it("embeds an inline image with the filename as alt text", (): void => {
        expect(attachmentMarkdown(fileLike("cat.png", "image/png"), "/attachments/h/cat.png")).toBe(
            "![cat.png](/attachments/h/cat.png)",
        );
    });

    it("links a non-image attachment with the filename as link text", (): void => {
        expect(attachmentMarkdown(fileLike("report.pdf", "application/pdf"), "/attachments/h/report.pdf")).toBe(
            "[report.pdf](/attachments/h/report.pdf)",
        );
    });
});

describe("uploadAttachment", (): void => {
    afterEach((): void => {
        vi.unstubAllGlobals();
    });

    it("posts the file as the raw body with the filename header and returns the stored URL", async (): Promise<void> => {
        const fetchMock = vi.fn(
            async (): Promise<Response> =>
                new Response(JSON.stringify({ url: "/attachments/abc/cat.png" }), { status: 200 }),
        );
        vi.stubGlobal("fetch", fetchMock);

        const url = await uploadAttachment(fileLike("a b.png", "image/png"));

        expect(url).toBe("/attachments/abc/cat.png");
        expect(fetchMock).toHaveBeenCalledWith("/attachments", {
            body: expect.any(File),
            headers: { "X-Attachment-Filename": "a%20b.png" },
            method: "POST",
        });
    });

    it.each([
        [413, "too large"],
        [415, "type"],
    ])("throws a helpful message on a %d response", async (status, fragment): Promise<void> => {
        vi.stubGlobal(
            "fetch",
            vi.fn(async (): Promise<Response> => new Response("no", { status })),
        );

        await expect(uploadAttachment(fileLike("x.exe", "application/octet-stream"))).rejects.toThrow(fragment);
    });

    it("throws when the response omits a URL", async (): Promise<void> => {
        vi.stubGlobal(
            "fetch",
            vi.fn(async (): Promise<Response> => new Response(JSON.stringify({}), { status: 200 })),
        );

        await expect(uploadAttachment(fileLike("cat.png", "image/png"))).rejects.toThrow();
    });
});
