// Extracts the `short_title` each page-relative image should carry in its sidecar `images.yaml`
// (RFC-0019, ADR-0049). The editor owns Markdown understanding (ADR-0040), so it derives the value here
// and sends `{localPath, shortTitle}` pairs with the save; the server only applies them. The rule is
// "the image's alt text, or the filename when the alt is empty" -- matching what the editor inserts on
// upload, so a freshly uploaded image's title is stable until the author edits its alt.

/** A page-relative image and the short_title its `images.yaml` entry should hold. */
export interface ImageShortTitle {
    localPath: string;
    shortTitle: string;
}

// A Markdown image whose destination is a page-relative `assets/...` path: `![alt](assets/x.png)`,
// tolerating an optional title (`"..."`) and surrounding whitespace inside the parentheses. A trailing
// `{width=N}` attribute list sits outside the parentheses and is ignored.
const ASSET_IMAGE = /!\[([^\]]*)\]\(\s*(assets\/[^)\s]+)(?:\s+"[^"]*")?\s*\)/g;

/** The final path segment of a page-relative path, used as the fallback short_title. */
function fileName(localPath: string): string {
    const segments = localPath.split("/");

    return segments[segments.length - 1] ?? localPath;
}

/**
 * The `{localPath, shortTitle}` for each page-relative image referenced in the Markdown, de-duplicated by
 * `localPath` (first occurrence wins). The short_title is the trimmed alt text, falling back to the
 * filename when the alt is empty. Only `assets/...` destinations are reported, since those are the ones
 * recorded in `images.yaml`; external images and other links are skipped.
 */
export function imageShortTitles(markdown: string): ImageShortTitle[] {
    const seen = new Set<string>();
    const titles: ImageShortTitle[] = [];

    for (const match of markdown.matchAll(ASSET_IMAGE)) {
        const alt = (match[1] ?? "").trim();
        const localPath = match[2] ?? "";

        if (localPath === "" || seen.has(localPath)) {
            continue;
        }

        seen.add(localPath);
        titles.push({ localPath, shortTitle: alt !== "" ? alt : fileName(localPath) });
    }

    return titles;
}
