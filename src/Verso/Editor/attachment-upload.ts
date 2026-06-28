// Uploads a file to the RFC-0018 attachment store (`POST /attachments`, raw body, percent-encoded
// `X-Attachment-Filename` header) and helps the editor decide how to reference the result: an inline
// `![alt](url)` image for the inline-renderable types, or a `[name](url)` download link for everything
// else (SVG, PDF, archives, ...). Pure classification and Markdown helpers are kept here so they are
// unit-tested independently of the editor's insertion seams.

/** The inline-renderable image extensions; mirrors the server's inline-disposition set (RFC-0018). */
const INLINE_IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "gif", "webp"];

/** The minimum a file needs for classification and Markdown; `File` satisfies it. */
interface UploadFile {
    name: string;
    type: string;
}

/** The lower-cased extension of a filename, or the empty string when it has none. */
function extensionOf(name: string): string {
    const dot = name.lastIndexOf(".");

    return dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
}

/**
 * Whether an uploaded file should be embedded as an inline image (`![]()`) rather than a download link.
 * SVG is deliberately excluded (the server serves it as a download, never inline). Classification is by
 * extension, falling back to the MIME type for a name without one (e.g. a pasted clipboard image).
 */
export function isInlineImage(file: UploadFile): boolean {
    const extension = extensionOf(file.name);

    if (extension) {
        return INLINE_IMAGE_EXTENSIONS.includes(extension);
    }

    return file.type.startsWith("image/") && file.type !== "image/svg+xml";
}

/** The Markdown reference for an uploaded file: an inline image embed or a download link. */
export function attachmentMarkdown(file: UploadFile, url: string): string {
    const text = file.name || "file";

    return isInlineImage(file) ? `![${text}](${url})` : `[${text}](${url})`;
}

/** A human-readable message for an upload failure status. */
function uploadErrorMessage(status: number): string {
    if (status === 413) {
        return "The file is too large to upload.";
    }

    if (status === 415) {
        return "This file type cannot be uploaded.";
    }

    return `The upload failed (status ${status}).`;
}

/** The shape of the upload response body (`{"url": "/attachments/<hash>/<name>"}`). */
interface UploadResponse {
    url?: unknown;
}

/**
 * Uploads a file to an attachment endpoint as a raw-body POST, returning the stored URL. The endpoint is
 * the content-addressed `/attachments` store by default, or a document's peer-`assets/` endpoint in the
 * tree-editing mode (which returns a page-relative URL). Throws an error with a user-facing message on a
 * non-OK status (e.g. 413 too large, 415 disallowed type) or a malformed response, so the editor can
 * surface it and insert nothing.
 */
export async function uploadAttachment(file: File, endpoint = "/attachments"): Promise<string> {
    const response = await fetch(endpoint, {
        body: file,
        headers: { "X-Attachment-Filename": encodeURIComponent(file.name) },
        method: "POST",
    });

    if (!response.ok) {
        throw new Error(uploadErrorMessage(response.status));
    }

    const payload = (await response.json()) as UploadResponse;

    if (typeof payload.url !== "string") {
        throw new Error("The upload returned no URL.");
    }

    return payload.url;
}
