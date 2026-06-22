// The path breadcrumb trail shown in the editor top bar (replacing the filename). The server walks the
// document's ancestor folders, reads each index.md's frontmatter title, and embeds the trail as JSON on the
// editor element; this parses it. Each crumb links to that folder's page, except the current page (the last
// crumb), which has no link.

/** One breadcrumb: a visible label and an optional link target (absent for the current page). */
export interface Breadcrumb {
    label: string;
    href?: string;
}

/** Parses the server-embedded `data-breadcrumbs` JSON into validated crumbs; `[]` on absence or malformed input. */
export function parseBreadcrumbs(json: string | null): Breadcrumb[] {
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

    const crumbs: Breadcrumb[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const label = (item as Record<string, unknown>)["label"];
            const href = (item as Record<string, unknown>)["href"];

            if (typeof label === "string") {
                crumbs.push(typeof href === "string" ? { href, label } : { label });
            }
        }
    }

    return crumbs;
}
