import { describe, expect, it } from "vitest";
import {
    checkEditorLayoutCss,
    editorLayoutMediaQueries,
    resolveEditorLayout,
} from "../../src/Verso/Editor/editor-layout.js";

describe("editor layout", (): void => {
    it("given the accepted threshold table, when media queries are published, then both owned thresholds are explicit", (): void => {
        expect(editorLayoutMediaQueries).toEqual({
            navPanel: "(max-width: 74rem)",
            panePanelWithRail: "(max-width: 93rem)",
        });
    });

    it("given a wide viewport, when layout is resolved, then navigation and metadata remain columns", (): void => {
        expect(
            resolveEditorLayout({
                navPanelQueryMatches: false,
                panePanelWithRailQueryMatches: false,
                railCollapsed: false,
            }),
        ).toEqual({ navIsPanel: false, paneIsPanel: false });
    });

    it("given the metadata query matches with the rail present, when layout is resolved, then metadata becomes a panel", (): void => {
        expect(
            resolveEditorLayout({
                navPanelQueryMatches: false,
                panePanelWithRailQueryMatches: true,
                railCollapsed: false,
            }),
        ).toEqual({ navIsPanel: false, paneIsPanel: true });
    });

    it("given the metadata query matches with the rail collapsed, when layout is resolved, then metadata remains a column", (): void => {
        expect(
            resolveEditorLayout({
                navPanelQueryMatches: false,
                panePanelWithRailQueryMatches: true,
                railCollapsed: true,
            }),
        ).toEqual({ navIsPanel: false, paneIsPanel: false });
    });

    it("given the navigation query matches with a collapsed rail preference, when layout is resolved, then both areas become panels", (): void => {
        expect(
            resolveEditorLayout({
                navPanelQueryMatches: true,
                panePanelWithRailQueryMatches: true,
                railCollapsed: true,
            }),
        ).toEqual({ navIsPanel: true, paneIsPanel: true });
    });

    it("given CSS with the owned navigation media query, when checked, then it agrees with the layout table", (): void => {
        const css = `
            @media (max-width: 74rem) {
                .markdown-editor__nav { display: none; }
            }
        `;

        expect(checkEditorLayoutCss(css)).toBeNull();
    });

    it("given CSS with a changed navigation media query, when checked, then the mismatch names both queries", (): void => {
        const css = `
            @media (max-width: 75rem) {
                .markdown-editor__nav { display: none; }
            }
        `;

        expect(checkEditorLayoutCss(css)).toBe(
            "Editor layout CSS expected navigation media query (max-width: 74rem), but found (max-width: 75rem).",
        );
    });

    it("given the owned navigation query appears only in a comment, when checked, then the query is reported absent", (): void => {
        const css = `
            /*
            @media (max-width: 74rem) {
                .markdown-editor__nav { display: none; }
            }
            */
        `;

        expect(checkEditorLayoutCss(css)).toBe(
            "Editor layout CSS expected navigation media query (max-width: 74rem), but no navigation media query was found.",
        );
    });
});
