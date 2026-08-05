import type { AdmonitionKind } from "./admonition-extension.js";
import type { CollapsibleKind } from "./collapsible-extension.js";

/** Block styles understood by both editing surfaces. */
export type VisualBlockStyle =
    | "paragraph"
    | "heading-1"
    | "heading-2"
    | "heading-3"
    | "heading-4"
    | "heading-5"
    | "heading-6";

/** Inline styles understood by both editing surfaces. */
export type VisualInlineStyle = "strong" | "emphasis" | "code" | "strikethrough" | "link";

/** Structural styles understood by both editing surfaces. */
export type VisualStructureStyle = "bullet-list" | "ordered-list" | "blockquote" | "code-block" | "thematic-break";

/** A document range captured from either editing surface. */
export interface EditingSelection {
    readonly from: number;
    readonly to: number;
}

/** A semantic edit which either surface can translate into its native command set. */
export type EditingCommand =
    | { readonly kind: "apply-block-style"; readonly style: VisualBlockStyle }
    | { readonly kind: "toggle-inline-style"; readonly style: VisualInlineStyle; readonly href?: string }
    | { readonly kind: "toggle-structure"; readonly style: VisualStructureStyle }
    | { readonly kind: "apply-badge"; readonly colour: string }
    | { readonly kind: "remove-badge" }
    | {
          readonly kind: "insert-structure";
          readonly structure: "table" | "admonition" | "collapsible";
          readonly admonitionKind?: AdmonitionKind;
          readonly collapsibleKind?: CollapsibleKind;
      }
    | { readonly kind: "insert-mermaid" }
    | { readonly kind: "insert-attachment"; readonly url: string; readonly text: string; readonly image: boolean }
    | { readonly kind: "set-link"; readonly href: string; readonly selection?: EditingSelection }
    | { readonly kind: "remove-link"; readonly selection: EditingSelection };

/** The host-facing interface shared by the source and visual editing adapters. */
export interface EditingSurface {
    /** Returns the stable element mounted in the editor chrome. */
    element(): HTMLDivElement;

    /** Serialises the surface's current document. */
    toMarkdown(): string;

    /** Replaces the surface's document without reporting a user edit. */
    setMarkdown(markdown: string): void;

    /** Applies one semantic editing command at the current or supplied selection. */
    applyCommand(command: EditingCommand): boolean;

    /** Returns the current non-empty selection, when one belongs to this surface. */
    currentSelection(): EditingSelection | null;

    /** Selects a document range and focuses the surface. */
    select(from: number, to: number): void;

    /** Places the caret at a document position and focuses the surface. */
    caretAt(position: number): void;

    /** Returns the viewport top of each top-level heading. */
    headingViewportTops(): readonly number[];

    /** Scrolls the indexed top-level heading into view. */
    scrollToHeading(index: number): void;

    /** Releases resources owned by the surface. */
    destroy(): void;
}
