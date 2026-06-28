import { describe, expect, it, vi } from "vitest";
import {
    AttachmentPanel,
    attachmentLinkMarkdown,
    type PanelAttachment,
    parseEmbeddedAttachments,
} from "../../src/Verso/Editor/attachment-panel.js";

describe("attachmentLinkMarkdown", (): void => {
    it("builds a Markdown link from the name and local path", (): void => {
        expect(attachmentLinkMarkdown({ name: "My Report.pdf", localPath: "assets/My_Report.pdf" })).toBe(
            "[My Report.pdf](assets/My_Report.pdf)",
        );
    });
});

describe("parseEmbeddedAttachments", (): void => {
    it("parses a JSON array of attachments", (): void => {
        const json = '[{"name":"A.pdf","localPath":"assets/A.pdf"},{"name":"B.pdf","localPath":"assets/B.pdf"}]';

        expect(parseEmbeddedAttachments(json)).toEqual([
            { name: "A.pdf", localPath: "assets/A.pdf" },
            { name: "B.pdf", localPath: "assets/B.pdf" },
        ]);
    });

    it("returns no attachments for a missing attribute", (): void => {
        expect(parseEmbeddedAttachments(null)).toEqual([]);
    });

    it("returns no attachments for malformed JSON", (): void => {
        expect(parseEmbeddedAttachments("{not json")).toEqual([]);
    });

    it("skips entries missing a name or local path", (): void => {
        const json = '[{"name":"A.pdf"},{"localPath":"assets/B.pdf"},{"name":"C.pdf","localPath":"assets/C.pdf"}]';

        expect(parseEmbeddedAttachments(json)).toEqual([{ name: "C.pdf", localPath: "assets/C.pdf" }]);
    });
});

describe("AttachmentPanel", (): void => {
    const sample: PanelAttachment[] = [
        { name: "A.pdf", localPath: "assets/A.pdf" },
        { name: "B.pdf", localPath: "assets/B.pdf" },
    ];

    it("lists each attachment as a link to its file", (): void => {
        const panel = new AttachmentPanel(() => {});
        panel.setAttachments(sample);

        const links = panel.element().querySelectorAll<HTMLAnchorElement>(".markdown-editor__attachment-link");
        expect(Array.from(links).map((link) => link.textContent)).toEqual(["A.pdf", "B.pdf"]);
        expect(links[0]?.getAttribute("href")).toBe("assets/A.pdf");
    });

    it("marks the panel empty when there are no attachments", (): void => {
        const panel = new AttachmentPanel(() => {});
        panel.setAttachments([]);

        expect(panel.element().dataset["empty"]).toBe("true");
    });

    it("calls back with the attachment when its insert action is used", (): void => {
        const onInsert = vi.fn();
        const panel = new AttachmentPanel(onInsert);
        panel.setAttachments(sample);

        panel.element().querySelectorAll<HTMLButtonElement>(".markdown-editor__attachment-insert")[0]?.click();

        expect(onInsert).toHaveBeenCalledWith(sample[0]);
    });

    it("appends a new attachment and dedupes by local path", (): void => {
        const panel = new AttachmentPanel(() => {});
        panel.setAttachments([]);

        panel.add({ name: "New.pdf", localPath: "assets/New.pdf" });
        panel.add({ name: "New.pdf", localPath: "assets/New.pdf" });

        const rows = panel.element().querySelectorAll(".markdown-editor__attachment");
        expect(rows.length).toBe(1);
        expect(panel.element().dataset["empty"]).toBe("false");
    });

    it("in read-only mode lists open links but omits the insert action and dragging", (): void => {
        const panel = new AttachmentPanel(() => {}, true);
        panel.setAttachments(sample);

        const links = panel.element().querySelectorAll<HTMLAnchorElement>(".markdown-editor__attachment-link");
        expect(Array.from(links).map((link) => link.getAttribute("href"))).toEqual(["assets/A.pdf", "assets/B.pdf"]);

        expect(panel.element().querySelectorAll(".markdown-editor__attachment-insert").length).toBe(0);
        const rows = panel.element().querySelectorAll<HTMLLIElement>(".markdown-editor__attachment");
        expect(Array.from(rows).every((row) => !row.hasAttribute("draggable"))).toBe(true);
    });
});
