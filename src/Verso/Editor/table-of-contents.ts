// A client-side generated table of contents (RHS panel). The Markdown body is the single source of truth
// for every view mode, so the contents are parsed from it directly -- no server round-trip, no drift between
// the rendered, source, and split views. The entries are in document order; an entry's index is the index of
// its heading element among the rendered headings, which the editor uses to scroll to it on click.

/** One contents entry: a heading's level (1-6) and its plain text. */
export interface TocEntry {
    level: number;
    text: string;
}

/** Callback fired with the index of the clicked contents entry (its heading's order in the document). */
export type TocSelectHandler = (index: number) => void;

/**
 * The contents panel shown in the right-hand sidebar. It renders the document headings as a clickable,
 * level-indented list and calls back with the clicked entry's index so the editor can scroll to the matching
 * heading. The panel hides itself when there are no headings.
 */
export class TableOfContentsPanel {
    private readonly panel: HTMLElement;
    private readonly list: HTMLOListElement;

    constructor(private readonly onSelect: TocSelectHandler) {
        this.panel = document.createElement("nav");
        this.panel.className = "markdown-editor__toc";
        this.panel.setAttribute("aria-label", "Table of contents");
        this.panel.hidden = true;

        const heading = document.createElement("h2");
        heading.className = "markdown-editor__metadata-heading";
        heading.textContent = "Contents";

        this.list = document.createElement("ol");
        this.list.className = "markdown-editor__toc-list";

        this.panel.append(heading, this.list);
    }

    /** The panel element, for placement in the editor sidebar. */
    public element(): HTMLElement {
        return this.panel;
    }

    /** Rebuilds the list from the given entries; hides the panel when there are none. */
    public setEntries(entries: TocEntry[]): void {
        this.list.replaceChildren();
        this.panel.hidden = entries.length === 0;

        entries.forEach((entry: TocEntry, index: number): void => {
            const item = document.createElement("li");
            item.className = "markdown-editor__toc-item";
            item.dataset["level"] = String(entry.level);

            const button = document.createElement("button");
            button.type = "button";
            button.className = "markdown-editor__toc-link";
            button.textContent = entry.text;
            // The delegated tooltip shows the full heading on hover (long entries truncate).
            button.setAttribute("data-tooltip", entry.text);
            button.addEventListener("click", (): void => this.onSelect(index));

            item.append(button);
            this.list.append(item);
        });
    }
}

const OPENING_FENCE = /^(\s*)(`{3,}|~{3,})/;
const ATX_HEADING = /^(#{1,6})\s+(.*)$/;

/**
 * Extracts the document's ATX headings (`#`..`######` at the line start, followed by a space) in order,
 * skipping any inside fenced code blocks (where a `#` line is code, not a heading). Setext headings and
 * indented headings (e.g. inside a list item or collapsible body) are intentionally not listed.
 */
export function documentHeadings(markdown: string): TocEntry[] {
    return scanHeadings(markdown).map(({ level, text }): TocEntry => ({ level, text }));
}

/**
 * The 0-based line numbers of the listed headings, in the same order as {@link documentHeadings}. The source
 * editor uses these to scroll its caret to the heading whose contents entry was clicked.
 */
export function headingLineNumbers(markdown: string): number[] {
    return scanHeadings(markdown).map(({ line }): number => line);
}

/** Scans the Markdown once, yielding each listed heading's level, plain text, and 0-based line number. */
function scanHeadings(markdown: string): Array<TocEntry & { line: number }> {
    const headings: Array<TocEntry & { line: number }> = [];
    const lines = markdown.split("\n");
    let fence: string | null = null;

    lines.forEach((line: string, index: number): void => {
        if (fence !== null) {
            if (new RegExp(`^\\s*${fence}{3,}\\s*$`).test(line)) {
                fence = null;
            }

            return;
        }

        const opening = OPENING_FENCE.exec(line);

        if (opening) {
            fence = (opening[2] ?? "")[0] === "~" ? "~" : "`";

            return;
        }

        const heading = ATX_HEADING.exec(line);

        if (heading) {
            const text = plainHeadingText(heading[2] ?? "");

            if (text !== "") {
                headings.push({ level: (heading[1] ?? "").length, line: index, text });
            }
        }
    });

    return headings;
}

/**
 * Reduces a heading's Markdown to plain text for display: drops the optional closing `#` sequence, unwraps
 * links to their text, and strips emphasis/strong/code/strikethrough markers. Approximate by design -- it is
 * a sidebar label, not a renderer.
 */
function plainHeadingText(raw: string): string {
    return raw
        .replace(/\s+#+\s*$/, "")
        .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
        .replace(/(\*\*|__|~~|\*|_|`)/g, "")
        .trim();
}
