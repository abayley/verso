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
