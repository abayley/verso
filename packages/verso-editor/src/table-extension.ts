import type { RootContent, TableCell, TableRow } from "mdast";
import type {
    ContentExtensionFor,
    ExtensionBlockInput,
    FromElementContext,
    ParseContext,
    ToMarkdownContext,
} from "./content-extension.js";
import type { InlineNode } from "./editor-model.js";

/** A column alignment, or null for an unaligned column. */
type TableAlign = "left" | "center" | "right" | null;

/** One table cell's inline content. */
type TableCellContent = InlineNode[];

/** The extension-owned payload carried on a custom table block. */
interface TableData {
    align: TableAlign[];
    header: TableCellContent[];
    rows: TableCellContent[][];
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        table: { block: TableData };
    }
}

/** Narrows an arbitrary value to a supported column alignment. */
function asAlign(value: unknown): TableAlign {
    return value === "left" || value === "center" || value === "right" ? value : null;
}

// Parse: a GFM `table` mdast node becomes a custom table block.

/** Converts a GFM table mdast node to a custom table block, declining any other node. */
function blockFromMdast(node: RootContent, ctx: ParseContext): ExtensionBlockInput<"table"> | null {
    if (node.type !== "table") {
        return null;
    }

    const [headerRow, ...bodyRows] = node.children;

    return {
        data: {
            align: (node.align ?? []).map((value): TableAlign => asAlign(value)),
            header: headerRow ? rowCellsFromMdast(headerRow, ctx) : [],
            rows: bodyRows.map((row: TableRow): TableCellContent[] => rowCellsFromMdast(row, ctx)),
        } satisfies TableData,
    };
}

/** Converts one mdast table row into editor cells. */
function rowCellsFromMdast(row: TableRow, ctx: ParseContext): TableCellContent[] {
    return row.children.map((cell: TableCell): TableCellContent => ctx.inlinesFromMdast(cell.children));
}

// Serialise-out: a custom table block becomes a GFM pipe table.

/** Serialises a custom table block to a GFM pipe table, declining any other block. */
function blockToMarkdown(data: TableData, _children: undefined, ctx: ToMarkdownContext): string {
    const columns = data.header.length;
    const delimiter = `| ${Array.from({ length: columns }, (_, column) => delimiterCell(data.align[column] ?? null)).join(" | ")} |`;

    return [rowToMarkdown(data.header, ctx), delimiter, ...data.rows.map((row) => rowToMarkdown(row, ctx))].join("\n");
}

/** Serialises one table row to a pipe-delimited Markdown line. */
function rowToMarkdown(cells: TableCellContent[], ctx: ToMarkdownContext): string {
    return `| ${cells.map((cell) => cellToMarkdown(cell, ctx)).join(" | ")} |`;
}

/** Serialises one cell's inline content, borrowing the paragraph seam and escaping pipes. */
function cellToMarkdown(cell: TableCellContent, ctx: ToMarkdownContext): string {
    return ctx.blockToMarkdown({ children: cell, type: "paragraph" }).replaceAll("|", "\\|");
}

/** Returns the delimiter-row cell for a column alignment. */
function delimiterCell(align: TableAlign): string {
    if (align === "left") {
        return ":---";
    }

    if (align === "center") {
        return ":---:";
    }

    if (align === "right") {
        return "---:";
    }

    return "---";
}

// Serialise-in: a rendered `<table>` element becomes a custom table block.

/** Converts a DOM table element (or a wrapper around one, as Tiptap renders it) to a custom table block. */
function blockFromElement(element: Element, ctx: FromElementContext): ExtensionBlockInput<"table"> | null {
    const table = element.tagName === "TABLE" ? element : element.querySelector(":scope > table");

    if (!table) {
        return null;
    }

    const rows = Array.from(table.querySelectorAll("tr"));
    const [headerRow, ...bodyRows] = rows;

    if (!headerRow) {
        return null;
    }

    return {
        data: {
            align: cellElements(headerRow).map((cell) => alignFromCell(cell)),
            header: rowCellsFromElement(headerRow, ctx),
            rows: bodyRows.map((row) => rowCellsFromElement(row, ctx)),
        } satisfies TableData,
    };
}

/** Returns the header and data cell elements of a table row. */
function cellElements(row: Element): Element[] {
    return Array.from(row.querySelectorAll("th, td"));
}

/** Converts one DOM table row into editor cells. */
function rowCellsFromElement(row: Element, ctx: FromElementContext): TableCellContent[] {
    return cellElements(row).map((cell) => cellInlinesFromElement(cell, ctx));
}

/** Reads a cell element's inline content by borrowing the paragraph seam. */
function cellInlinesFromElement(cell: Element, ctx: FromElementContext): TableCellContent {
    const block = ctx.blockFromElement(cell);

    return block.type === "paragraph" ? block.children : [];
}

/** Reads a cell element's column alignment from its inline style or align attribute. */
function alignFromCell(cell: Element): TableAlign {
    return asAlign((cell as HTMLElement).style.textAlign || cell.getAttribute("align"));
}

/** GFM pipe tables recognised, rendered, and serialised through the content-extension registry. */
export const tableExtension: ContentExtensionFor<"table"> = {
    blockFromElement,
    blockFromMdast,
    blockToMarkdown,
    name: "table",
};
