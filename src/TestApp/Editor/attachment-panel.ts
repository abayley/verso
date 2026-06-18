// The metadata panel's attachment list (RFC-0019). The server embeds the page's attachments (name +
// page-relative local_path) on the editor element as JSON; this module parses that, builds the panel DOM,
// and surfaces each attachment so the author can open it, insert a link to it, or drag it into the
// document. Attachments not linked from the body still appear here -- surfacing them is the panel's point.

/** A page attachment as embedded by the server and shown in the panel. */
export interface PanelAttachment {
    name: string;
    localPath: string;
}

/** The drag MIME type carrying a dragged attachment, so the editor's drop handler recognises its own drags. */
export const ATTACHMENT_DRAG_TYPE = "application/x-md-attachment";

/** The Markdown link inserted for an attachment: `[name](assets/...)`. */
export function attachmentLinkMarkdown(attachment: PanelAttachment): string {
    return `[${attachment.name}](${attachment.localPath})`;
}

/** Parse the server-embedded `data-attachments` JSON into validated attachments; `[]` on absence or malformed input. */
export function parseEmbeddedAttachments(json: string | null): PanelAttachment[] {
    if (!json) {
        return [];
    }

    let parsed: unknown;
    try {
        parsed = JSON.parse(json);
    } catch {
        return [];
    }

    if (!Array.isArray(parsed)) {
        return [];
    }

    const attachments: PanelAttachment[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const name = (item as Record<string, unknown>)["name"];
            const localPath = (item as Record<string, unknown>)["localPath"];
            if (typeof name === "string" && typeof localPath === "string" && localPath !== "") {
                attachments.push({ name, localPath });
            }
        }
    }

    return attachments;
}

/**
 * The editor's metadata panel: a right-hand region listing the page's attachments. Each row links to the
 * file (opens in a new tab), offers an insert action that calls back into the editor, and is draggable so
 * it can be dropped into the document. New uploads are pushed in with `add` (deduplicated by `localPath`).
 */
export class AttachmentPanel {
    private readonly panel: HTMLElement;
    private readonly list: HTMLUListElement;
    private readonly seen = new Set<string>();

    constructor(
        private readonly onInsert: (attachment: PanelAttachment) => void,
        private readonly readonly = false,
    ) {
        this.panel = document.createElement("aside");
        this.panel.className = "markdown-editor__metadata-panel";
        this.panel.setAttribute("aria-label", "Page metadata");
        this.panel.dataset["empty"] = "true";

        const heading = document.createElement("h2");
        heading.className = "markdown-editor__metadata-heading";
        heading.textContent = "Attachments";

        this.list = document.createElement("ul");
        this.list.className = "markdown-editor__attachment-list";

        const empty = document.createElement("p");
        empty.className = "markdown-editor__attachment-empty";
        empty.textContent = "No attachments yet.";

        this.panel.append(heading, this.list, empty);
    }

    /** The panel element, for placement in the editor chrome. */
    public element(): HTMLElement {
        return this.panel;
    }

    /** Replace the listed attachments with the given set (initial load). */
    public setAttachments(attachments: PanelAttachment[]): void {
        this.list.replaceChildren();
        this.seen.clear();
        for (const attachment of attachments) {
            this.add(attachment);
        }
    }

    /** Append an attachment row, ignoring one whose `localPath` is already listed. */
    public add(attachment: PanelAttachment): void {
        if (this.seen.has(attachment.localPath)) {
            return;
        }

        this.seen.add(attachment.localPath);
        this.list.append(this.createRow(attachment));
        this.panel.dataset["empty"] = "false";
    }

    private createRow(attachment: PanelAttachment): HTMLLIElement {
        const row = document.createElement("li");
        row.className = "markdown-editor__attachment";

        const link = document.createElement("a");
        link.className = "markdown-editor__attachment-link";
        link.href = attachment.localPath;
        link.target = "_blank";
        link.rel = "noopener";
        link.textContent = attachment.name;
        row.append(link);

        // In the read view the panel is a plain list of files to open; the insert action and drag-to-insert
        // both mutate the document, so they are omitted there (RFC-0020).
        if (this.readonly) {
            return row;
        }

        row.draggable = true;
        row.addEventListener("dragstart", (event: DragEvent): void => {
            event.dataTransfer?.setData(ATTACHMENT_DRAG_TYPE, JSON.stringify(attachment));
            event.dataTransfer?.setData("text/plain", attachmentLinkMarkdown(attachment));
        });

        const insert = document.createElement("button");
        insert.type = "button";
        insert.className = "markdown-editor__attachment-insert";
        insert.textContent = "Insert";
        insert.addEventListener("click", (): void => this.onInsert(attachment));
        row.append(insert);

        return row;
    }
}
