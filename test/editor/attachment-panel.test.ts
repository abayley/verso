import { describe, expect, it, vi } from "vitest";
import {
    AttachmentPanel,
    attachmentLinkMarkdown,
    type PanelAttachment,
    parseEmbeddedAttachments,
} from "../../src/Verso/Editor/attachment-panel.js";

describe("attachmentLinkMarkdown", (): void => {
    it("given a name and a local path, when a link is built, then it is Markdown pointing at that path", (): void => {
        expect(attachmentLinkMarkdown({ name: "My Report.pdf", localPath: "assets/My_Report.pdf" })).toBe(
            "[My Report.pdf](assets/My_Report.pdf)",
        );
    });
});

describe("parseEmbeddedAttachments", (): void => {
    it("given a JSON array of attachments, when parsed, then each attachment is returned", (): void => {
        const json = '[{"name":"A.pdf","localPath":"assets/A.pdf"},{"name":"B.pdf","localPath":"assets/B.pdf"}]';

        expect(parseEmbeddedAttachments(json)).toEqual([
            { name: "A.pdf", localPath: "assets/A.pdf" },
            { name: "B.pdf", localPath: "assets/B.pdf" },
        ]);
    });

    it("given a missing attribute, when parsed, then no attachments are returned", (): void => {
        expect(parseEmbeddedAttachments(null)).toEqual([]);
    });

    it("given malformed JSON, when parsed, then no attachments are returned", (): void => {
        expect(parseEmbeddedAttachments("{not json")).toEqual([]);
    });

    it("given entries missing a name or local path, when parsed, then those entries are skipped", (): void => {
        const json = '[{"name":"A.pdf"},{"localPath":"assets/B.pdf"},{"name":"C.pdf","localPath":"assets/C.pdf"}]';

        expect(parseEmbeddedAttachments(json)).toEqual([{ name: "C.pdf", localPath: "assets/C.pdf" }]);
    });
});

describe("AttachmentPanel", (): void => {
    const sample: PanelAttachment[] = [
        { name: "A.pdf", localPath: "assets/A.pdf" },
        { name: "B.pdf", localPath: "assets/B.pdf" },
    ];

    it("given several attachments, when the panel renders, then each is listed as a link to its file", (): void => {
        const panel = new AttachmentPanel(() => {});
        panel.setAttachments(sample);

        const links = panel.element().querySelectorAll<HTMLAnchorElement>(".markdown-editor__attachment-link");
        expect(Array.from(links).map((link) => link.textContent)).toEqual(["A.pdf", "B.pdf"]);
        expect(links[0]?.getAttribute("href")).toBe("assets/A.pdf");
    });

    it("given no attachments, when the panel renders, then it is marked empty", (): void => {
        const panel = new AttachmentPanel(() => {});
        panel.setAttachments([]);

        expect(panel.element().dataset["empty"]).toBe("true");
    });

    it("given a listed attachment, when its insert action is used, then the callback receives that attachment", (): void => {
        const onInsert = vi.fn();
        const panel = new AttachmentPanel(onInsert);
        panel.setAttachments(sample);

        panel.element().querySelectorAll<HTMLButtonElement>(".markdown-editor__attachment-insert")[0]?.click();

        expect(onInsert).toHaveBeenCalledWith(sample[0]);
    });

    it("given an attachment already listed, when the same local path is added, then it is not duplicated", (): void => {
        const panel = new AttachmentPanel(() => {});
        panel.setAttachments([]);

        panel.add({ name: "New.pdf", localPath: "assets/New.pdf" });
        panel.add({ name: "New.pdf", localPath: "assets/New.pdf" });

        const rows = panel.element().querySelectorAll(".markdown-editor__attachment");
        expect(rows.length).toBe(1);
        expect(panel.element().dataset["empty"]).toBe("false");
    });

    it("given read-only mode, when the panel renders, then open links are listed and the insert action and dragging are omitted", (): void => {
        const panel = new AttachmentPanel(() => {}, true);
        panel.setAttachments(sample);

        const links = panel.element().querySelectorAll<HTMLAnchorElement>(".markdown-editor__attachment-link");
        expect(Array.from(links).map((link) => link.getAttribute("href"))).toEqual(["assets/A.pdf", "assets/B.pdf"]);

        expect(panel.element().querySelectorAll(".markdown-editor__attachment-insert").length).toBe(0);
        const rows = panel.element().querySelectorAll<HTMLLIElement>(".markdown-editor__attachment");
        expect(Array.from(rows).every((row) => !row.hasAttribute("draggable"))).toBe(true);
    });
});
