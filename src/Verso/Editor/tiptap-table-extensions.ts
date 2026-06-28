import type { Extensions } from "@tiptap/core";
import { Table, TableCell, TableHeader, TableRow } from "@tiptap/extension-table";

/** Reads a supported column alignment from a cell element's inline style or align attribute. */
function alignFromElement(element: HTMLElement): string | null {
    const value = element.style.textAlign || element.getAttribute("align");

    return value === "left" || value === "center" || value === "right" ? value : null;
}

/** Renders a `textAlign` attribute to an inline style, or nothing when unset. */
function alignToAttributes(value: unknown): Record<string, string> {
    return value === "left" || value === "center" || value === "right" ? { style: `text-align: ${value}` } : {};
}

/** The `textAlign` attribute shared by header and data cells, carrying GFM column alignment. */
const alignAttribute = {
    textAlign: {
        default: null,
        parseHTML: (element: HTMLElement): string | null => alignFromElement(element),
        renderHTML: (attributes: Record<string, unknown>): Record<string, string> =>
            alignToAttributes(attributes["textAlign"]),
    },
};

const TableHeaderWithAlign = TableHeader.extend({
    addAttributes() {
        return { ...this.parent?.(), ...alignAttribute };
    },
});

const TableCellWithAlign = TableCell.extend({
    addAttributes() {
        return { ...this.parent?.(), ...alignAttribute };
    },
});

/** GFM table nodes for Tiptap: header and data cells carry a `textAlign` attribute for column alignment. */
export const tableExtensions: Extensions = [
    Table.configure({ resizable: false }),
    TableRow,
    TableHeaderWithAlign,
    TableCellWithAlign,
];
