/** Browser media query state and the stored navigation rail preference. */
export interface EditorLayoutInput {
    readonly navPanelQueryMatches: boolean;
    readonly panePanelWithRailQueryMatches: boolean;
    readonly railCollapsed: boolean;
}

/** The layout state consumed by the editor host. */
export interface EditorLayout {
    readonly navIsPanel: boolean;
    readonly paneIsPanel: boolean;
}

interface EditorLayoutThresholds {
    readonly navPanelRem: number;
    readonly panePanelWithRailRem: number;
}

const editorLayoutThresholds: EditorLayoutThresholds = {
    navPanelRem: 74,
    panePanelWithRailRem: 93,
};

/** Formats an owned rem threshold as a browser media query. */
function maxWidthMediaQuery(thresholdRem: number): string {
    return `(max-width: ${thresholdRem}rem)`;
}

/** Media queries derived from the editor layout threshold table. */
export const editorLayoutMediaQueries = {
    navPanel: maxWidthMediaQuery(editorLayoutThresholds.navPanelRem),
    panePanelWithRail: maxWidthMediaQuery(editorLayoutThresholds.panePanelWithRailRem),
} as const;

interface CssMediaBlock {
    readonly query: string;
    readonly body: string;
}

/** Removes CSS comments before authored rules are inspected. */
function stripCssComments(css: string): string {
    return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

/** Finds the closing brace for one CSS block, including nested rule blocks. */
function closingBraceIndex(css: string, openingBraceIndex: number): number | null {
    let depth = 0;
    for (let index = openingBraceIndex; index < css.length; index += 1) {
        const character = css[index];
        if (character === "{") {
            depth += 1;
        } else if (character === "}") {
            depth -= 1;
            if (depth === 0) {
                return index;
            }
        }
    }
    return null;
}

/** Extracts top-level media query text and bodies from stylesheet text. */
function cssMediaBlocks(css: string): readonly CssMediaBlock[] {
    const blocks: CssMediaBlock[] = [];
    for (const match of css.matchAll(/@media\s*(\([^{}]+\))\s*\{/g)) {
        const query = match[1];
        if (query === undefined || match.index === undefined) {
            continue;
        }
        const openingBraceIndex = match.index + match[0].lastIndexOf("{");
        const closingIndex = closingBraceIndex(css, openingBraceIndex);
        if (closingIndex !== null) {
            blocks.push({ query, body: css.slice(openingBraceIndex + 1, closingIndex) });
        }
    }
    return blocks;
}

/** Checks that handwritten CSS uses the navigation query owned by this module. */
export function checkEditorLayoutCss(css: string): string | null {
    const expectedQuery = editorLayoutMediaQueries.navPanel;
    const navigationQueries = cssMediaBlocks(stripCssComments(css))
        .filter((block) => block.body.includes(".markdown-editor__nav"))
        .map((block) => block.query);
    if (navigationQueries.includes(expectedQuery)) {
        return null;
    }
    if (navigationQueries.length === 0) {
        return `Editor layout CSS expected navigation media query ${expectedQuery}, but no navigation media query was found.`;
    }
    return `Editor layout CSS expected navigation media query ${expectedQuery}, but found ${navigationQueries.join(", ")}.`;
}

/** Resolves editor navigation and metadata layout without reading browser state. */
export function resolveEditorLayout(input: EditorLayoutInput): EditorLayout {
    const navIsPanel = input.navPanelQueryMatches;
    return {
        navIsPanel,
        paneIsPanel: navIsPanel || (input.panePanelWithRailQueryMatches && !input.railCollapsed),
    };
}
