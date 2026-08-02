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
 * Which entries are being read, by the rule "the section intersects the viewport": an entry's section runs
 * from its own heading down to the next heading of the same or a higher level (to the end of the document
 * for the last one), and the entry is active when that span overlaps the band of the viewport the document
 * actually shows. Measuring the section rather than the heading means the indicator always marks something,
 * however deep inside one long section the reader is -- a heading-only rule goes blank as soon as the
 * heading itself scrolls away.
 *
 * Nesting is deliberate: a subsection in view also marks its ancestors, whose sections contain it. The
 * active entries are therefore not always one contiguous run (an ancestor stays lit while a sibling
 * subsection above the fold does not), which is why each entry is marked in its own right.
 *
 * `tops` are viewport coordinates of each heading, in the same order as the entries; a heading with no
 * measurement (a shorter array, or a NaN from an unrendered view) is never active.
 */
export function activeSections(levels: number[], tops: number[], bandTop: number, bandBottom: number): boolean[] {
    return levels.map((level: number, index: number): boolean => {
        const start = tops[index];

        if (start === undefined || Number.isNaN(start)) {
            return false;
        }

        const next = levels.findIndex((other: number, at: number): boolean => at > index && other <= level);
        const end = next === -1 ? Number.POSITIVE_INFINITY : (tops[next] ?? Number.POSITIVE_INFINITY);

        return start < bandBottom && end > bandTop;
    });
}

/**
 * The contents panel shown in the right-hand sidebar. It renders the document headings as a clickable,
 * level-indented list and calls back with the clicked entry's index so the editor can scroll to the matching
 * heading. The panel hides itself when there are no headings.
 */
export class TableOfContentsPanel {
    private readonly panel: HTMLElement;
    private readonly list: HTMLOListElement;
    private levels: number[] = [];
    /** The last marking applied, so a scroll that changes nothing touches neither the DOM nor the scroller. */
    private active: boolean[] = [];

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
        this.levels = entries.map((entry: TocEntry): number => entry.level);
        this.active = [];

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

    /**
     * Marks the entries whose sections are on screen, given each heading's viewport top and the band of the
     * viewport the document shows (below the sticky top bar, above the fold). The marked entries carry the
     * indicator rail; the list then scrolls itself so they stay in view on a document with more headings
     * than the pane is tall.
     */
    public trackReading(tops: number[], bandTop: number, bandBottom: number): void {
        const active = activeSections(this.levels, tops, bandTop, bandBottom);

        if (active.length === this.active.length && active.every((on, at): boolean => on === this.active[at])) {
            return;
        }

        this.active = active;
        const items = [...this.list.children];
        items.forEach((item: Element, index: number): void => {
            (item as HTMLElement).dataset["active"] = active[index] === true ? "true" : "false";
        });
        this.revealActive(items.filter((_item: Element, index: number): boolean => active[index] === true));
    }

    /**
     * Scrolls the pane by the least that brings the marked entries into view, keeping the first of them
     * visible when they do not all fit. Only the pane's own scroller is moved -- never the page, which
     * `scrollIntoView` would drag along with it, fighting the very scroll that triggered this.
     */
    private revealActive(marked: Element[]): void {
        const first = marked[0];
        const last = marked[marked.length - 1];
        const scroller = scrollableAncestor(this.panel);

        if (first === undefined || last === undefined || scroller === null) {
            return;
        }

        const view = scroller.getBoundingClientRect();
        const above = first.getBoundingClientRect().top - view.top;
        const below = last.getBoundingClientRect().bottom - view.bottom;

        if (above < 0) {
            scroller.scrollTop += above;
        } else if (below > 0) {
            scroller.scrollTop += Math.min(below, above);
        }
    }
}

/** The nearest ancestor that actually scrolls, which for the contents panel is the sidebar column. */
function scrollableAncestor(element: HTMLElement): HTMLElement | null {
    let candidate = element.parentElement;

    while (candidate !== null) {
        const overflow = getComputedStyle(candidate).overflowY;

        if ((overflow === "auto" || overflow === "scroll") && candidate.scrollHeight > candidate.clientHeight) {
            return candidate;
        }

        candidate = candidate.parentElement;
    }

    return null;
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
