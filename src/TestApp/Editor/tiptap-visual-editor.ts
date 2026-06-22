import { Editor, Extension, type JSONContent, type SetContentOptions } from "@tiptap/core";
import Heading from "@tiptap/extension-heading";
import { Markdown } from "@tiptap/markdown";
import {
    Fragment,
    type Mark as ProseMirrorMark,
    type MarkType as ProseMirrorMarkType,
    type Node as ProseMirrorNode,
    type NodeType as ProseMirrorNodeType,
    type ResolvedPos,
    type Schema,
} from "@tiptap/pm/model";
import { Plugin } from "@tiptap/pm/state";
import { CellSelection, selectionCell } from "@tiptap/pm/tables";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import StarterKit from "@tiptap/starter-kit";
import { type AdmonitionKind, matchAlertMarker } from "./admonition-extension.js";
import { type CollapsibleKind, matchCollapsibleMarker } from "./collapsible-extension.js";
import { widthFromAttributes } from "./image-extension.js";
import { isAllowedLinkUri } from "./link-uri.js";
import { documentFromElements, documentToMarkdown } from "./markdown-serialise.js";
import { badgeSpans, rawHtmlSpans } from "./remark-adapter.js";
import { Admonition } from "./tiptap-admonition-node.js";
import { Badge } from "./tiptap-badge-mark.js";
import { Collapsible } from "./tiptap-collapsible-node.js";
import { FootnoteDefinition, FootnoteReference } from "./tiptap-footnote-node.js";
import { Image } from "./tiptap-image-node.js";
import { RawHtml, RawHtmlBlock } from "./tiptap-raw-html-node.js";
import { ReferenceDefinition, ReferenceLink } from "./tiptap-reference-link-node.js";
import { tableExtensions } from "./tiptap-table-extensions.js";

/** Callback fired when the visual editor content changes. */
export type TiptapChangeHandler = () => void;

/** Callback fired when the visual editor requests link target input. */
export type TiptapLinkShortcutHandler = () => void;

/** Supported visual block styles exposed by the editor toolbar. */
export type VisualBlockStyle =
    | "paragraph"
    | "heading-1"
    | "heading-2"
    | "heading-3"
    | "heading-4"
    | "heading-5"
    | "heading-6";

/** Supported visual inline styles exposed by the editor toolbar. */
export type VisualInlineStyle = "strong" | "emphasis" | "code" | "strikethrough" | "link";

/** Supported visual structure commands exposed by the editor toolbar. */
export type VisualStructureStyle = "bullet-list" | "ordered-list" | "blockquote" | "code-block" | "thematic-break";

/** Supported table-editing commands exposed when the selection is inside a table. */
export type VisualTableCommand = "row-after" | "row-delete" | "column-after" | "column-delete" | "delete";

/** A link mark range resolved from the rendered visual editor. */
export interface VisualLinkSelection {
    from: number;
    href: string;
    to: number;
}

type MarkdownSetContentOptions = SetContentOptions & {
    contentType: "markdown";
};

/** The `@tiptap/markdown` extension augments the editor with a Markdown parser used to re-parse bodies. */
interface MarkdownParseEditor {
    markdown: {
        parse(markdown: string): JSONContent;
    };
}

/** A footnote definition pulled out of the raw Markdown before marked parses it. */
interface FootnoteDefinitionSource {
    id: string;
    markdown: string;
}

/**
 * Pulls GFM footnote definitions (`[^id]: body`, with four-space/tab-indented continuation lines) out of
 * the Markdown before marked sees it. marked has no footnote support and would treat a single-token
 * definition as a link reference definition (turning `[^id]` into a link and swallowing the body); removing
 * the definitions leaves the `[^id]` references as literal text, which {@link loadFootnotes} promotes.
 */
function extractFootnoteDefinitions(markdown: string): { definitions: FootnoteDefinitionSource[]; stripped: string } {
    const lines = markdown.split("\n");
    const bodyLines: string[] = [];
    const definitions: FootnoteDefinitionSource[] = [];

    for (let index = 0; index < lines.length; index += 1) {
        const match = /^\[\^([^\]\s]+)\]:[ \t]?(.*)$/.exec(lines[index] ?? "");

        if (!match) {
            bodyLines.push(lines[index] ?? "");

            continue;
        }

        const definitionLines = [match[2] ?? ""];

        while (index + 1 < lines.length) {
            const next = lines[index + 1] ?? "";

            if (next.trim() === "") {
                definitionLines.push("");
                index += 1;
            } else if (/^( {4}|\t)/.test(next)) {
                definitionLines.push(next.replace(/^( {4}|\t)/, ""));
                index += 1;
            } else {
                break;
            }
        }

        while (definitionLines.length > 0 && definitionLines[definitionLines.length - 1] === "") {
            definitionLines.pop();
        }

        definitions.push({ id: match[1] ?? "", markdown: definitionLines.join("\n") });
    }

    return { definitions, stripped: bodyLines.join("\n") };
}

/** A link reference definition pulled out of the raw Markdown before marked parses it. */
interface ReferenceDefinitionSource {
    label: string;
    title: string | null;
    url: string;
}

/**
 * Pulls link reference definitions (`[label]: url "title"`, single line) out of the Markdown before
 * marked sees it. marked would otherwise consume them as link reference definitions and resolve
 * `[text][label]` into a plain inline link (losing the reference form); removing them leaves the
 * references as literal text, which {@link loadReferenceLinks} promotes to reference-link marks.
 */
function extractReferenceDefinitions(markdown: string): { definitions: ReferenceDefinitionSource[]; stripped: string } {
    const lines = markdown.split("\n");
    const bodyLines: string[] = [];
    const definitions: ReferenceDefinitionSource[] = [];

    for (const line of lines) {
        const match = /^\[([^^\]][^\]]*)\]:[ \t]+(\S+)(?:[ \t]+"([^"]*)")?[ \t]*$/.exec(line);

        if (match) {
            definitions.push({ label: match[1] ?? "", title: match[3] ?? null, url: match[2] ?? "" });
        } else {
            bodyLines.push(line);
        }
    }

    return { definitions, stripped: bodyLines.join("\n") };
}

/** Normalises a reference label for matching (case-fold + collapse whitespace), as CommonMark does. */
function normaliseReferenceLabel(label: string): string {
    return label.trim().replace(/\s+/gu, " ").toLowerCase();
}

// Private-use sentinels marking where a raw-HTML fragment was extracted, so marked passes them through as
// plain text; {@link TiptapVisualEditor.loadRawHtml} swaps them for raw-html nodes after the content loads.
const RAW_HTML_SENTINEL = /\u{E000}(\d+)\u{E001}/gu;

/** A raw-HTML fragment pulled out before marked: the verbatim HTML and whether it was block-level. */
interface RawHtmlFragment {
    html: string;
    block: boolean;
}

// Private-use sentinels marking where a badge lozenge was extracted (distinct from the raw-HTML pair), so
// marked passes them through as plain text; {@link TiptapVisualEditor.loadBadges} swaps each for its text
// carrying the badge mark.
const BADGE_SENTINEL = /\u{E002}(\d+)\u{E003}/gu;

/** A badge lozenge pulled out before marked: its literal text and colour. */
interface BadgeFragment {
    text: string;
    colour: string;
}

// Private-use sentinels (\u{E004}..\u{E005}, distinct from the raw-HTML and badge pairs) mark where a fenced
// code block was extracted. @tiptap/markdown mangles a fenced code block inside a list item whose content
// has a blank line (it truncates at the blank line -- marked tokenises it correctly, the bug is the
// token->ProseMirror conversion), so the fence is pulled out before loading and
// {@link TiptapVisualEditor.loadFencedCode} swaps the sentinel paragraph back for a code-block node (RFC-0025).

/** A fenced code block pulled out before marked: its language (info string) and verbatim content. */
interface FencedCodeFragment {
    language: string | null;
    content: string;
}

/**
 * Replaces every fenced code block (``` or `~~~`) with an indexed sentinel on its own line at the fence's
 * indentation, returning the stripped Markdown and the fragments by index. Run before the other extractors
 * so fence *content* (which may contain footnote/badge/raw-HTML syntax, or list-like lines) is protected.
 * Content is de-indented by the opening fence's indent, as CommonMark fenced code is. An unclosed fence is
 * left untouched (not a code block).
 */
function stripFencedCode(markdown: string): { stripped: string; fragments: FencedCodeFragment[] } {
    const lines = markdown.split("\n");
    const fragments: FencedCodeFragment[] = [];
    const output: string[] = [];
    const opener = /^(\s*)(`{3,}|~{3,})([^`]*)$/u;
    let index = 0;

    while (index < lines.length) {
        const line = lines[index] ?? "";
        const match = opener.exec(line);

        if (!match) {
            output.push(line);
            index += 1;
            continue;
        }

        const indent = match[1] ?? "";
        const fence = match[2] ?? "";
        const language = (match[3] ?? "").trim() || null;
        const closer = new RegExp(`^\\s*${fence[0] === "~" ? "~" : "`"}{${fence.length},}\\s*$`, "u");
        const content: string[] = [];
        let scan = index + 1;

        while (scan < lines.length && !closer.test(lines[scan] ?? "")) {
            content.push(stripLeadingSpaces(lines[scan] ?? "", indent.length));
            scan += 1;
        }

        if (scan >= lines.length) {
            // No closing fence: not a code block. Emit the opener verbatim and carry on past it.
            output.push(line);
            index += 1;
            continue;
        }

        // Separate the sentinel paragraph from its neighbours with a single blank line each side, without
        // creating a double blank (two blank lines would end the enclosing list item and strand later
        // sentinels). The leading blank is added only if the previous output line is not already blank; the
        // trailing blank only if the next source line is not already blank.
        if (output.length > 0 && output[output.length - 1] !== "") {
            output.push("");
        }

        output.push(`${indent}\u{E004}${fragments.length}\u{E005}`);

        const next = lines[scan + 1];
        if (next !== undefined && next.trim() !== "") {
            output.push("");
        }

        fragments.push({ content: content.join("\n"), language });
        index = scan + 1;
    }

    return { fragments, stripped: output.join("\n") };
}

/** Removes up to `count` leading space characters from a line (the fenced-code de-indent). */
function stripLeadingSpaces(line: string, count: number): string {
    let removed = 0;

    while (removed < count && line[removed] === " ") {
        removed += 1;
    }

    return line.slice(removed);
}

/**
 * Replaces each badge lozenge (`` `text`{.badge.<colour>} ``) with an indexed sentinel before marked sees
 * it (marked would split the code span from its attribute list), returning the stripped Markdown and the
 * fragments by index. Spans are replaced last-to-first so earlier source offsets stay valid.
 */
function stripBadges(markdown: string): { stripped: string; fragments: BadgeFragment[] } {
    const spans = badgeSpans(markdown).sort((a, b): number => a.start - b.start);

    if (spans.length === 0) {
        return { fragments: [], stripped: markdown };
    }

    const fragments = spans.map((span): BadgeFragment => ({ colour: span.colour, text: span.text }));
    let stripped = markdown;

    for (let index = spans.length - 1; index >= 0; index -= 1) {
        const span = spans[index];

        if (span) {
            stripped = `${stripped.slice(0, span.start)}\u{E002}${index}\u{E003}${stripped.slice(span.end)}`;
        }
    }

    return { fragments, stripped };
}

/**
 * Replaces each raw-HTML span with an indexed sentinel before marked sees it (marked otherwise interprets
 * or drops raw HTML), returning the stripped Markdown and the verbatim fragments by index. Spans are
 * replaced last-to-first so earlier source offsets stay valid. A block-level span's sentinel is wrapped in
 * blank lines so marked keeps it as its own paragraph -- otherwise an export comment on the line after an
 * image would be merged onto the image's line ({@link TiptapVisualEditor.loadRawHtml} then promotes such a
 * sentinel paragraph to a block node).
 */
function stripRawHtml(markdown: string): { stripped: string; fragments: RawHtmlFragment[] } {
    const spans = rawHtmlSpans(markdown).sort((a, b): number => a.start - b.start);

    if (spans.length === 0) {
        return { fragments: [], stripped: markdown };
    }

    const fragments = spans.map((span): RawHtmlFragment => ({ block: span.block, html: span.value }));
    let stripped = markdown;

    for (let index = spans.length - 1; index >= 0; index -= 1) {
        const span = spans[index];

        if (span) {
            const sentinel = `\u{E000}${index}\u{E001}`;
            const replacement = span.block ? `\n\n${sentinel}\n\n` : sentinel;
            stripped = `${stripped.slice(0, span.start)}${replacement}${stripped.slice(span.end)}`;
        }
    }

    return { fragments, stripped };
}

const HeadingWithoutInputRules = Heading.extend({
    /** Keeps heading nodes available while preventing typed hash shortcuts. */
    addInputRules() {
        return [];
    },
});

/**
 * Marks the empty paragraph holding the collapsed caret with `is-empty` and a `data-placeholder` of
 * "Type / for commands" -- the slash-menu hint. A decoration computed from state (no dispatched transaction,
 * unlike `@tiptap/extensions`' Placeholder, whose viewport plugin dispatches during construction and would
 * fire `onUpdate` before the editor is assigned). The hint is only *shown* under the Studio theme, gated in
 * CSS on `data-editor-theme`; under the toolbar-driven themes the attribute is present but never rendered, so
 * a runtime theme switch (which only toggles the root attribute) needs no editor rebuild.
 */
const SlashHint = Extension.create({
    name: "slashHint",

    addProseMirrorPlugins() {
        return [
            new Plugin({
                props: {
                    decorations: (state) => {
                        const { $from, empty } = state.selection;
                        const node = $from.parent;

                        if (!empty || node.type.name !== "paragraph" || node.content.size > 0) {
                            return null;
                        }

                        const pos = $from.before();

                        return DecorationSet.create(state.doc, [
                            Decoration.node(pos, pos + node.nodeSize, {
                                class: "is-empty",
                                "data-placeholder": "Type / for commands",
                            }),
                        ]);
                    },
                },
            }),
        ];
    },
});

/** Markdown-in/Markdown-out adapter around Tiptap's visual editor. */
export class TiptapVisualEditor {
    private readonly editor: Editor;
    private normalisingSoftBreaks = false;
    private readonly onLinkShortcut: TiptapLinkShortcutHandler;
    private readonly root: HTMLDivElement;
    private readonly preserveRawHtml: boolean;

    /** Creates a Tiptap editor mounted inside a stable root element. */
    public constructor(
        markdown: string,
        onChange: TiptapChangeHandler,
        onLinkShortcut: TiptapLinkShortcutHandler,
        options: { preserveRawHtml?: boolean; editable?: boolean } = {},
    ) {
        this.root = document.createElement("div");
        this.root.className = "markdown-editor__surface";
        this.onLinkShortcut = onLinkShortcut;
        this.preserveRawHtml = options.preserveRawHtml ?? false;

        const fences = stripFencedCode(markdown);
        const footnotes = extractFootnoteDefinitions(fences.stripped);
        const references = extractReferenceDefinitions(footnotes.stripped);
        const raw = this.extractRawHtml(references.stripped);
        const badges = this.extractBadges(raw.stripped);
        const editable = options.editable ?? true;

        this.editor = new Editor({
            content: badges.stripped,
            contentType: "markdown",
            editable,
            element: this.root,
            extensions: [
                StarterKit.configure({
                    heading: false,
                    // Page-relative links (`assets/x.pdf`, RFC-0019) have no URI scheme; Tiptap's default
                    // href sanitisation drops them to an empty href. `isAllowedLinkUri` permits scheme-less
                    // relative URLs while keeping the default validation for absolute ones.
                    //
                    // Links open in a new tab while editing (so the editor is not navigated away from), but
                    // in the read view (RFC-0020) they navigate in place for normal browsing.
                    link: {
                        isAllowedUri: (
                            url: string,
                            ctx: { defaultValidate: (candidate: string) => boolean },
                        ): boolean => isAllowedLinkUri(url, ctx.defaultValidate),
                        HTMLAttributes: editable
                            ? { target: "_blank", rel: "noopener noreferrer nofollow" }
                            : { target: null, rel: null },
                    },
                }),
                HeadingWithoutInputRules,
                Admonition,
                Collapsible,
                FootnoteReference,
                FootnoteDefinition,
                ReferenceLink,
                ReferenceDefinition,
                Image,
                RawHtml,
                RawHtmlBlock,
                Badge,
                SlashHint,
                ...tableExtensions,
                Markdown.configure({
                    markedOptions: {
                        gfm: true,
                    },
                }),
            ],
            injectCSS: false,
            editorProps: {
                handleKeyDown: (_view, event: KeyboardEvent): boolean => this.handleKeyDown(event),
            },
            onUpdate: (): void => {
                if (this.normalisingSoftBreaks) {
                    return;
                }

                if (this.applyListMarkerShortcut()) {
                    return;
                }

                onChange();
            },
        });
        // Wrap bare top-level images first: a standalone image loads as a schema-invalid document, and the
        // upgrade passes below dispatch transactions that throw "Called contentMatchAt on a node with invalid
        // content" over such a document (see wrapBareImages). Validity must be restored before any transaction.
        this.wrapBareImages();
        this.upgradeAlertBlockquotes();
        this.upgradeCollapsibles();
        // After upgradeCollapsibles: a fence inside a collapsible rides through the body re-parse as a
        // sentinel paragraph, so this one pass restores fences both top-level and inside collapsibles.
        this.loadFencedCode(fences.fragments);
        this.loadImageWidths();
        this.loadRawHtml(raw.fragments);
        this.loadBadges(badges.fragments);
        this.loadFootnotes(footnotes.definitions);
        this.loadReferenceLinks(references.definitions);
        this.collapseSoftBreaks();
    }

    /** Returns the root element that hosts the Tiptap editor. */
    public element(): HTMLDivElement {
        return this.root;
    }

    /** Scrolls the n-th top-level heading into view (the contents panel's click target). */
    public scrollToHeading(index: number): void {
        const headings = this.root.querySelectorAll(
            ".ProseMirror > h1, .ProseMirror > h2, .ProseMirror > h3, .ProseMirror > h4, .ProseMirror > h5, .ProseMirror > h6",
        );

        headings[index]?.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    /** Serialises the current Tiptap document to Markdown. */
    public toMarkdown(): string {
        const markdown = documentToMarkdown(documentFromElements(editorContentElements(this.editor.view.dom)));

        return escapeLiteralParagraphMarkers(markdown, this.editor.getJSON());
    }

    /** Replaces the current visual document from Markdown. */
    public setMarkdown(markdown: string): void {
        const options: MarkdownSetContentOptions = {
            contentType: "markdown",
            emitUpdate: false,
        };

        const fences = stripFencedCode(markdown);
        const footnotes = extractFootnoteDefinitions(fences.stripped);
        const references = extractReferenceDefinitions(footnotes.stripped);
        const raw = this.extractRawHtml(references.stripped);
        const badges = this.extractBadges(raw.stripped);
        this.editor.commands.setContent(badges.stripped, options);
        // Wrap bare top-level images first: a standalone image loads as a schema-invalid document, and the
        // upgrade passes below dispatch transactions that throw "Called contentMatchAt on a node with invalid
        // content" over such a document (see wrapBareImages). Validity must be restored before any transaction.
        this.wrapBareImages();
        this.upgradeAlertBlockquotes();
        this.upgradeCollapsibles();
        this.loadFencedCode(fences.fragments);
        this.loadImageWidths();
        this.loadRawHtml(raw.fragments);
        this.loadBadges(badges.fragments);
        this.loadFootnotes(footnotes.definitions);
        this.loadReferenceLinks(references.definitions);
        this.collapseSoftBreaks();
    }

    /** Pre-extracts raw HTML (sentinels for marked) when preservation is on; a no-op passthrough otherwise. */
    private extractRawHtml(markdown: string): { stripped: string; fragments: RawHtmlFragment[] } {
        return this.preserveRawHtml ? stripRawHtml(markdown) : { fragments: [], stripped: markdown };
    }

    /** Pre-extracts badge lozenges (sentinels for marked) when preservation is on; a no-op otherwise. */
    private extractBadges(markdown: string): { stripped: string; fragments: BadgeFragment[] } {
        return this.preserveRawHtml ? stripBadges(markdown) : { fragments: [], stripped: markdown };
    }

    /**
     * Replaces the badge sentinels left by {@link extractBadges} with the badge text carrying the `badge`
     * mark (with its colour), after the content has loaded. marked passes the sentinels through as text;
     * this swaps each for the lozenge's text so it renders as a pill and round-trips.
     */
    private loadBadges(fragments: BadgeFragment[]): void {
        if (fragments.length === 0) {
            return;
        }

        const badgeMark = this.editor.state.schema.marks["badge"];

        if (!badgeMark) {
            return;
        }

        const replacements: Array<{ from: number; to: number; text: string; colour: string }> = [];

        this.editor.state.doc.descendants((node: ProseMirrorNode, position: number): boolean => {
            if (!node.isText || node.text === undefined) {
                return true;
            }

            const pattern = new RegExp(BADGE_SENTINEL.source, "gu");
            let match = pattern.exec(node.text);

            while (match !== null) {
                const fragment = fragments[Number(match[1])];

                if (fragment !== undefined && fragment.text !== "") {
                    replacements.push({
                        colour: fragment.colour,
                        from: position + match.index,
                        text: fragment.text,
                        to: position + match.index + match[0].length,
                    });
                }

                match = pattern.exec(node.text);
            }

            return true;
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.sort((a, b): number => b.from - a.from)) {
            transaction.replaceWith(
                replacement.from,
                replacement.to,
                this.editor.state.schema.text(replacement.text, [badgeMark.create({ colour: replacement.colour })]),
            );
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /**
     * Replaces the raw-HTML sentinels left by {@link extractRawHtml} with raw-html nodes after the content
     * has loaded. A block fragment's sentinel sits alone in its own paragraph (stripRawHtml wrapped it in
     * blank lines), which is promoted whole to a block raw-html node so it keeps its own line; an inline
     * fragment's sentinel is swapped in place for an inline raw-html node. Either way the HTML survives the
     * round-trip inert, never interpreted or rendered live.
     */
    private loadRawHtml(fragments: RawHtmlFragment[]): void {
        if (fragments.length === 0) {
            return;
        }

        const rawHtmlType = this.editor.state.schema.nodes["rawHtml"];
        const rawHtmlBlockType = this.editor.state.schema.nodes["rawHtmlBlock"];

        if (!rawHtmlType || !rawHtmlBlockType) {
            return;
        }

        const replacements: Array<{ from: number; node: ProseMirrorNode; to: number }> = [];

        this.editor.state.doc.descendants((node: ProseMirrorNode, position: number): boolean => {
            // A paragraph whose sole content is a block fragment's sentinel becomes a block raw-html node.
            if (node.type.name === "paragraph") {
                const wholeMatch = /^\u{E000}(\d+)\u{E001}$/u.exec(node.textContent);
                const fragment = wholeMatch ? fragments[Number(wholeMatch[1])] : undefined;

                if (wholeMatch && fragment?.block) {
                    replacements.push({
                        from: position,
                        node: rawHtmlBlockType.create({ html: fragment.html }),
                        to: position + node.nodeSize,
                    });

                    return false;
                }
            }

            if (!node.isText || node.text === undefined) {
                return true;
            }

            const pattern = new RegExp(RAW_HTML_SENTINEL.source, "gu");
            let match = pattern.exec(node.text);

            while (match !== null) {
                const fragment = fragments[Number(match[1])];

                if (fragment !== undefined) {
                    replacements.push({
                        from: position + match.index,
                        node: rawHtmlType.create({ html: fragment.html }, null, node.marks),
                        to: position + match.index + match[0].length,
                    });
                }

                match = pattern.exec(node.text);
            }

            return true;
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.sort((a, b): number => b.from - a.from)) {
            transaction.replaceWith(replacement.from, replacement.to, replacement.node);
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /**
     * Replaces the fenced-code sentinels left by {@link stripFencedCode} with code-block nodes after the
     * content has loaded. Each sentinel sits alone in its own paragraph (in the correct list item or
     * collapsible, since a plain paragraph survives the loader's nesting), and is promoted whole to a
     * code-block node carrying the verbatim content and language (RFC-0025).
     */
    private loadFencedCode(fragments: FencedCodeFragment[]): void {
        if (fragments.length === 0) {
            return;
        }

        const codeBlockType = this.editor.state.schema.nodes["codeBlock"];

        if (!codeBlockType) {
            return;
        }

        const replacements: Array<{ from: number; node: ProseMirrorNode; to: number }> = [];

        this.editor.state.doc.descendants((node: ProseMirrorNode, position: number): boolean => {
            if (node.type.name !== "paragraph") {
                return true;
            }

            // Tolerate surrounding whitespace: @tiptap/markdown indents continuation paragraphs inside a
            // loose list item, so a later sentinel comes back as e.g. "  <sentinel>" rather than bare.
            const match = /^\s*\u{E004}(\d+)\u{E005}\s*$/u.exec(node.textContent);
            const fragment = match ? fragments[Number(match[1])] : undefined;

            if (match && fragment) {
                const attrs = fragment.language === null ? {} : { language: fragment.language };
                const content = fragment.content.length > 0 ? this.editor.state.schema.text(fragment.content) : null;
                replacements.push({
                    from: position,
                    node: codeBlockType.create(attrs, content),
                    to: position + node.nodeSize,
                });

                return false;
            }

            return true;
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.sort((a, b): number => b.from - a.from)) {
            transaction.replaceWith(replacement.from, replacement.to, replacement.node);
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /**
     * Promotes GFM alert blockquotes (`> [!NOTE]` ...) into admonition nodes after content loads.
     * Runs before {@link collapseSoftBreaks} so the marker is still on its own line in the text.
     */
    private upgradeAlertBlockquotes(): void {
        const schema = this.editor.state.schema;

        if (!schema.nodes["admonition"]) {
            return;
        }

        const replacements: Array<{ from: number; node: ProseMirrorNode; to: number }> = [];

        this.editor.state.doc.descendants((node: ProseMirrorNode, position: number): boolean => {
            if (node.type.name !== "blockquote") {
                return true;
            }

            const admonition = admonitionFromBlockquote(schema, node);

            if (admonition) {
                replacements.push({ from: position, node: admonition, to: position + node.nodeSize });

                return false;
            }

            return true;
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.reverse()) {
            transaction.replaceWith(replacement.from, replacement.to, replacement.node);
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /** Inserts an admonition callout of the given kind around the current selection. */
    public insertAdmonition(kind: AdmonitionKind): boolean {
        return this.editor.chain().focus().wrapIn("admonition", { kind }).run();
    }

    /** Inserts a collapsed collapsible callout of the given type around the current selection. */
    public insertCollapsible(kind: CollapsibleKind): boolean {
        return this.editor.chain().focus().wrapIn("collapsible", { collapsibleType: kind }).run();
    }

    /**
     * Promotes a mkdocs collapsible (a `??? type` marker paragraph followed by the indented body, which
     * marked loads as a code block) into a collapsible node after content loads, re-parsing the body
     * Markdown into rich nodes. Runs before {@link collapseSoftBreaks} so the body content is normalised too.
     */
    private upgradeCollapsibles(): void {
        const schema = this.editor.state.schema;
        const collapsibleType = schema.nodes["collapsible"];

        if (!collapsibleType) {
            return;
        }

        const doc = this.editor.state.doc;
        const replacements: Array<{ from: number; node: ProseMirrorNode; to: number }> = [];

        doc.forEach((node: ProseMirrorNode, offset: number, index: number): void => {
            if (node.type.name !== "paragraph") {
                return;
            }

            const marker = matchCollapsibleMarker(node.textContent);
            const body = index + 1 < doc.childCount ? doc.child(index + 1) : null;

            if (!marker || !body || body.type.name !== "codeBlock") {
                return;
            }

            replacements.push({
                from: offset,
                node: this.collapsibleNode(collapsibleType, marker, body.textContent),
                to: offset + node.nodeSize + body.nodeSize,
            });
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.reverse()) {
            transaction.replaceWith(replacement.from, replacement.to, replacement.node);
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /** Builds a collapsible node, re-parsing the body Markdown into rich child nodes. */
    private collapsibleNode(
        collapsibleType: ProseMirrorNodeType,
        marker: { kind: CollapsibleKind; title: string | null; open: boolean },
        bodyMarkdown: string,
    ): ProseMirrorNode {
        const schema = this.editor.state.schema;
        const parsed = (this.editor as unknown as MarkdownParseEditor).markdown.parse(bodyMarkdown);
        const bodyDoc = schema.nodeFromJSON(parsed);
        const bodyNodes: ProseMirrorNode[] = [];

        bodyDoc.content.forEach((child: ProseMirrorNode): void => {
            bodyNodes.push(child);
        });

        if (bodyNodes.length === 0) {
            const paragraphType = schema.nodes["paragraph"];

            if (paragraphType) {
                bodyNodes.push(paragraphType.create());
            }
        }

        return collapsibleType.create(
            { collapsibleType: marker.kind, open: marker.open, title: marker.title },
            Fragment.fromArray(bodyNodes),
        );
    }

    /**
     * Wraps any bare top-level image in a paragraph. A standalone `![](url)` line loads (via marked and the
     * image node's parse handler) as an image node that is a *direct child of the document*, but the image
     * node is inline, so the document is then schema-invalid (the doc allows only blocks). ProseMirror
     * tolerates the load but a later insert (e.g. an upload at the caret) throws "Called contentMatchAt on a
     * node with invalid content" while fitting the change. Wrapping each top-level image in a paragraph
     * restores a valid document; an inline image already inside a paragraph is untouched.
     *
     * The wrap rebuilds the document from corrected JSON via `setContent` rather than splicing the live
     * (invalid) document: an in-place `replaceWith` leaves the model valid but the browser's view
     * unreconciled (a phantom empty `<img>` lingers in the DOM, which the DOM-reading serialiser then emits
     * as a stray `![]()`); re-setting the content re-renders the view cleanly from a valid model.
     */
    private wrapBareImages(): void {
        const content = this.editor.getJSON().content ?? [];
        let wrappedAny = false;
        const wrapped = content.map((node: JSONContent): JSONContent => {
            if (node.type === "image") {
                wrappedAny = true;

                return { content: [node], type: "paragraph" };
            }

            return node;
        });

        if (!wrappedAny) {
            return;
        }

        this.editor.commands.setContent({ content: wrapped, type: "doc" }, { emitUpdate: false });
    }

    /**
     * Applies a `{width=N}` attribute list that follows an image. marked has no attribute-list support, so
     * the `{width=N}` after a loaded image stays as literal text; this promotes that text onto the image
     * node's `width` attribute (the resize node view and the DOM serialise seam then keep it round-tripping)
     * and removes the consumed text. Mirrors the source pipeline's `remarkImageWidth` for the marked path.
     */
    private loadImageWidths(): void {
        const replacements: Array<{
            attrs: Record<string, unknown>;
            from: number;
            imagePos: number;
            to: number;
            width: number;
        }> = [];

        this.editor.state.doc.descendants(
            (node: ProseMirrorNode, position: number, parent: ProseMirrorNode | null, index: number): boolean => {
                if (!node.isText || node.text === undefined || !parent || index === 0) {
                    return true;
                }

                const previous = parent.child(index - 1);

                if (previous.type.name !== "image") {
                    return true;
                }

                const match = /^\{([^}]*)\}/.exec(node.text);
                const width = match ? widthFromAttributes(match[1] ?? "") : null;

                if (!match || width === null) {
                    return true;
                }

                replacements.push({
                    attrs: previous.attrs,
                    from: position,
                    imagePos: position - previous.nodeSize,
                    to: position + match[0].length,
                    width,
                });

                return true;
            },
        );

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.reverse()) {
            transaction.delete(replacement.from, replacement.to);
            transaction.setNodeMarkup(replacement.imagePos, undefined, {
                ...replacement.attrs,
                width: replacement.width,
            });
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /**
     * Loads GFM footnotes after content loads. The definitions were pre-extracted before marked saw the
     * Markdown (marked would otherwise consume a single-token `[^id]: dest` as a link reference definition
     * and turn `[^id]` into a link): they are appended as definition nodes here, and the now-literal
     * `[^id]` references are promoted to inline reference nodes. Runs before {@link collapseSoftBreaks}.
     */
    private loadFootnotes(definitions: FootnoteDefinitionSource[]): void {
        if (definitions.length === 0) {
            return;
        }

        const schema = this.editor.state.schema;
        const definitionType = schema.nodes["footnoteDefinition"];
        const referenceType = schema.nodes["footnoteReference"];

        if (!definitionType || !referenceType) {
            return;
        }

        this.appendFootnoteDefinitions(definitionType, definitions);
        this.upgradeFootnoteReferences(referenceType, new Set(definitions.map((definition) => definition.id)));
    }

    /** Appends one footnote definition node per pre-extracted definition, re-parsing each body's Markdown. */
    private appendFootnoteDefinitions(
        definitionType: ProseMirrorNodeType,
        definitions: FootnoteDefinitionSource[],
    ): void {
        const schema = this.editor.state.schema;
        const paragraphType = schema.nodes["paragraph"];
        const nodes = definitions.map((definition: FootnoteDefinitionSource): ProseMirrorNode => {
            const parsed = (this.editor as unknown as MarkdownParseEditor).markdown.parse(definition.markdown);
            const bodyDoc = schema.nodeFromJSON(parsed);
            const bodyNodes: ProseMirrorNode[] = [];

            bodyDoc.content.forEach((child: ProseMirrorNode): void => {
                bodyNodes.push(child);
            });

            if (bodyNodes.length === 0 && paragraphType) {
                bodyNodes.push(paragraphType.create());
            }

            return definitionType.create({ footnoteId: definition.id }, Fragment.fromArray(bodyNodes));
        });

        const transaction = this.editor.state.tr;
        transaction.insert(this.editor.state.doc.content.size, Fragment.fromArray(nodes));
        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /** Replaces `[^id]` text matching a known definition with inline footnote reference nodes. */
    private upgradeFootnoteReferences(referenceType: ProseMirrorNodeType, ids: Set<string>): void {
        const replacements: Array<{ from: number; id: string; marks: readonly ProseMirrorMark[]; to: number }> = [];

        this.editor.state.doc.descendants((node: ProseMirrorNode, position: number): boolean => {
            if (!node.isText || node.text === undefined) {
                return true;
            }

            const pattern = /\[\^([^\]\s]+)\]/g;
            let match = pattern.exec(node.text);

            while (match !== null) {
                const id = match[1] ?? "";

                if (ids.has(id)) {
                    replacements.push({
                        from: position + match.index,
                        id,
                        // Carry the text's marks onto the atom so a reference inside e.g. bold stays inside it.
                        marks: node.marks,
                        to: position + match.index + match[0].length,
                    });
                }

                match = pattern.exec(node.text);
            }

            return true;
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.reverse()) {
            transaction.replaceWith(
                replacement.from,
                replacement.to,
                referenceType.create({ footnoteId: replacement.id }, null, replacement.marks),
            );
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /**
     * Loads link reference definitions (pre-extracted before marked, like footnotes): appends them as
     * definition nodes and promotes full `[text][id]` and collapsed `[text][]` references to reference-link
     * marks (so they show as links and round-trip). Shortcut `[text]` references stay literal text.
     */
    private loadReferenceLinks(definitions: ReferenceDefinitionSource[]): void {
        if (definitions.length === 0) {
            return;
        }

        const schema = this.editor.state.schema;
        const definitionType = schema.nodes["referenceDefinition"];
        const markType = schema.marks["referenceLink"];

        if (!definitionType || !markType) {
            return;
        }

        this.appendReferenceDefinitions(definitionType, definitions);
        const byLabel = new Map<string, ReferenceDefinitionSource>();

        for (const definition of definitions) {
            byLabel.set(normaliseReferenceLabel(definition.label), definition);
        }

        this.upgradeReferenceLinks(markType, byLabel);
    }

    /** Appends one definition node per pre-extracted link reference definition. */
    private appendReferenceDefinitions(
        definitionType: ProseMirrorNodeType,
        definitions: ReferenceDefinitionSource[],
    ): void {
        const nodes = definitions.map(
            (definition: ReferenceDefinitionSource): ProseMirrorNode =>
                definitionType.create({ label: definition.label, title: definition.title, url: definition.url }),
        );
        const transaction = this.editor.state.tr;
        transaction.insert(this.editor.state.doc.content.size, Fragment.fromArray(nodes));
        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /** Replaces `[text][id]` / `[text][]` text matching a definition with reference-link-marked text. */
    private upgradeReferenceLinks(
        markType: ProseMirrorMarkType,
        byLabel: Map<string, ReferenceDefinitionSource>,
    ): void {
        const schema = this.editor.state.schema;
        const replacements: Array<{
            from: number;
            label: string;
            marks: readonly ProseMirrorMark[];
            referenceType: string;
            text: string;
            title: string | null;
            to: number;
            url: string;
        }> = [];

        this.editor.state.doc.descendants((node: ProseMirrorNode, position: number): boolean => {
            if (!node.isText || node.text === undefined) {
                return true;
            }

            const pattern = /\[([^[\]]+)\]\[([^[\]]*)\]/g;
            let match = pattern.exec(node.text);

            while (match !== null) {
                const text = match[1] ?? "";
                const rawLabel = match[2] ?? "";
                const definition = byLabel.get(normaliseReferenceLabel(rawLabel === "" ? text : rawLabel));

                if (definition) {
                    replacements.push({
                        from: position + match.index,
                        label: rawLabel === "" ? definition.label : rawLabel,
                        marks: node.marks,
                        referenceType: rawLabel === "" ? "collapsed" : "full",
                        text,
                        title: definition.title,
                        to: position + match.index + match[0].length,
                        url: definition.url,
                    });
                }

                match = pattern.exec(node.text);
            }

            return true;
        });

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.reverse()) {
            const mark = markType.create({
                label: replacement.label,
                referenceType: replacement.referenceType,
                title: replacement.title,
                url: replacement.url,
            });
            transaction.replaceWith(
                replacement.from,
                replacement.to,
                schema.text(replacement.text, [...replacement.marks, mark]),
            );
        }

        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
    }

    /** Inserts a 3x3 GFM table with a header row at the current selection. */
    public insertTable(): boolean {
        return this.editor.chain().focus().insertTable({ cols: 3, rows: 3, withHeaderRow: true }).run();
    }

    /** Inserts an inline image (uploaded attachment) at the current selection. */
    public insertImage(src: string, alt: string): boolean {
        return this.editor
            .chain()
            .focus()
            .insertContent({ attrs: { alt, src, title: null }, type: "image" })
            .run();
    }

    /** Inserts a link to an uploaded attachment, with the filename as the link text, at the selection. */
    public insertFileLink(url: string, text: string): boolean {
        return this.editor
            .chain()
            .focus()
            .insertContent({ marks: [{ attrs: { href: url }, type: "link" }], text, type: "text" })
            .run();
    }

    /** Applies (or recolours) the badge mark on the selection (RFC-0021). */
    public applyBadge(colour: string): boolean {
        return this.editor.chain().focus().setMark("badge", { colour }).run();
    }

    /** Removes the badge mark from the selection. */
    public removeBadge(): boolean {
        return this.editor.chain().focus().unsetMark("badge").run();
    }

    /** Reports whether the selection is inside a table (for showing the table controls). */
    public isInTable(): boolean {
        return this.selectedTable() !== null;
    }

    /** Returns the bounding rectangle of the table containing the selection, for anchoring the controls. */
    public tableRect(): DOMRect | null {
        const table = this.selectedTable();

        return table ? table.getBoundingClientRect() : null;
    }

    /**
     * The table element containing the current DOM selection, or null. Read from the DOM selection (not
     * `editor.isActive`, which lags the click on first focus) so the controls appear on the first click in a
     * cell, not only after a second selection change.
     */
    private selectedTable(): HTMLElement | null {
        const node = window.getSelection()?.anchorNode;

        if (!node || !this.root.contains(node)) {
            return null;
        }

        const element = node.nodeType === Node.ELEMENT_NODE ? (node as Element) : node.parentElement;

        return element?.closest("table") ?? null;
    }

    /** Runs one table-editing command at the current selection. */
    public runTableCommand(command: VisualTableCommand): boolean {
        const chain = this.editor.chain().focus();

        switch (command) {
            case "row-after":
                return chain.addRowAfter().run();
            case "row-delete":
                return chain.deleteRow().run();
            case "column-after":
                return chain.addColumnAfter().run();
            case "column-delete":
                return chain.deleteColumn().run();
            case "delete":
                return chain.deleteTable().run();
        }
    }

    /**
     * Sets the GFM column alignment for the whole column containing the selection -- header and data cells
     * alike. Column alignment is a property of the column (the header cell drives the serialised delimiter),
     * so aligning only the selected cell changed nothing in the Markdown and reverted on reload. Selecting
     * the column first makes setCellAttribute apply to every cell, so the column aligns immediately and the
     * delimiter round-trips.
     */
    public setColumnAlignment(align: "left" | "center" | "right" | null): boolean {
        return this.editor
            .chain()
            .focus()
            .command(({ state, tr, dispatch }): boolean => {
                let cell: ResolvedPos;

                try {
                    cell = selectionCell(state);
                } catch {
                    return false;
                }

                if (dispatch) {
                    tr.setSelection(CellSelection.colSelection(cell));
                }

                return true;
            })
            .setCellAttribute("textAlign", align)
            .run();
    }

    /** Replaces soft line breaks in non-code text with spaces, matching CommonMark rendering. */
    private collapseSoftBreaks(): void {
        const replacements: Array<{ from: number; to: number; text: string }> = [];

        this.editor.state.doc.descendants(
            (node: ProseMirrorNode, position: number, parent: ProseMirrorNode | null): boolean => {
                if (node.isText && node.text?.includes("\n") && parent?.type.name !== "codeBlock") {
                    replacements.push({
                        from: position,
                        text: node.text.replaceAll("\n", " "),
                        to: position + node.nodeSize,
                    });
                }

                return true;
            },
        );

        if (replacements.length === 0) {
            return;
        }

        const transaction = this.editor.state.tr;

        for (const replacement of replacements.reverse()) {
            transaction.insertText(replacement.text, replacement.from, replacement.to);
        }

        this.normalisingSoftBreaks = true;
        this.editor.view.dispatch(transaction.setMeta("addToHistory", false));
        this.normalisingSoftBreaks = false;
    }

    /** Applies one supported block style at the current visual selection. */
    public applyBlockStyle(style: VisualBlockStyle): boolean {
        if (style === "paragraph") {
            return this.editor.chain().focus().setParagraph().run();
        }

        return this.editor
            .chain()
            .focus()
            .setHeading({
                level: headingLevel(style),
            })
            .run();
    }

    /** Toggles one supported inline style at the current visual selection. */
    public toggleInlineStyle(style: VisualInlineStyle, href?: string): boolean {
        const selection = this.currentVisualSelection();

        switch (style) {
            case "strong": {
                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleBold().run(),
                );
            }

            case "emphasis": {
                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleItalic().run(),
                );
            }

            case "code": {
                const codeSelection = this.trimSelectionEndingAtBlockStart(selection);
                const selectedText = codeSelection
                    ? this.editor.state.doc.textBetween(codeSelection.from, codeSelection.to, "\n\n", "\n")
                    : "";

                if (selectedText.includes("\n")) {
                    return this.withCurrentSelection(codeSelection, (editor: Editor): boolean =>
                        editor
                            .chain()
                            .focus()
                            .insertContent({
                                content: [
                                    {
                                        text: selectedText,
                                        type: "text",
                                    },
                                ],
                                type: "codeBlock",
                            })
                            .run(),
                    );
                }

                return this.withCurrentSelection(codeSelection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleCode().run(),
                );
            }

            case "strikethrough": {
                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().toggleStrike().run(),
                );
            }

            case "link": {
                if (!href) {
                    return false;
                }

                return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                    editor.chain().focus().setLink({ href }).run(),
                );
            }
        }
    }

    /** Returns the block style at the current selection (for the bubble toolbar's block selector). */
    public currentBlockStyle(): VisualBlockStyle {
        for (const level of [1, 2, 3, 4, 5, 6] as const) {
            if (this.editor.isActive("heading", { level })) {
                return `heading-${level}`;
            }
        }

        return "paragraph";
    }

    /** Reports whether an inline style is active at the current selection (for the bubble toolbar). */
    public isInlineActive(style: VisualInlineStyle): boolean {
        switch (style) {
            case "strong":
                return this.editor.isActive("bold");
            case "emphasis":
                return this.editor.isActive("italic");
            case "code":
                return this.editor.isActive("code");
            case "strikethrough":
                return this.editor.isActive("strike");
            case "link":
                return this.editor.isActive("link");
        }
    }

    /** Reports whether the caret sits in a textblock whose only text is a slash trigger. */
    public isSlashTrigger(): boolean {
        const resolved = this.caretBlock();

        return resolved?.parent.isTextblock === true && resolved.parent.textContent === "/";
    }

    /** Returns the caret rectangle for slash menu placement, or null when it cannot be resolved. */
    public slashCaretRect(): DOMRect | null {
        const selection = window.getSelection();

        if (!this.isSlashTrigger() || !selection || selection.rangeCount === 0) {
            return null;
        }

        return selection.getRangeAt(0).getBoundingClientRect();
    }

    /** Removes the leading slash of the current block before a slash command runs. */
    public deleteSlashTrigger(): void {
        const resolved = this.caretBlock();

        if (!resolved) {
            return;
        }

        const start = resolved.start();

        this.editor
            .chain()
            .focus()
            .deleteRange({ from: start, to: start + 1 })
            .run();
    }

    /** Resolves the document position of the textblock holding the current DOM caret. */
    private caretBlock(): ResolvedPos | null {
        const selection = window.getSelection();

        if (!selection?.anchorNode || !selection.isCollapsed || !this.root.contains(selection.anchorNode)) {
            return null;
        }

        const position = this.editor.view.posAtDOM(selection.anchorNode, selection.anchorOffset);

        return this.editor.state.doc.resolve(position);
    }

    /** Resolves a rendered link element to the Tiptap document range it covers. */
    public linkSelectionFromAnchor(anchor: HTMLAnchorElement): VisualLinkSelection | null {
        if (!this.root.contains(anchor)) {
            return null;
        }

        const first = firstTextDescendant(anchor);
        const last = lastTextDescendant(anchor);

        if (!first || !last) {
            return null;
        }

        const from = this.editor.view.posAtDOM(first, 0);
        const to = this.editor.view.posAtDOM(last, last.data.length);

        return {
            from: Math.min(from, to),
            href: anchor.getAttribute("href") ?? "",
            to: Math.max(from, to),
        };
    }

    /** Updates the link target at a previously resolved visual link range. */
    public setLinkAt(selection: VisualLinkSelection, href: string): boolean {
        return this.withCurrentSelection(selection, (editor: Editor): boolean =>
            editor.chain().focus().setLink({ href }).run(),
        );
    }

    /** Removes the link mark at a previously resolved visual link range. */
    public unsetLinkAt(selection: VisualLinkSelection): boolean {
        return this.withCurrentSelection(selection, (editor: Editor): boolean =>
            editor.chain().focus().unsetLink().run(),
        );
    }

    /** Toggles one supported structural style at the current visual selection. */
    public toggleStructure(style: VisualStructureStyle): boolean {
        if (style === "bullet-list") {
            return this.editor.chain().focus().toggleBulletList().run();
        }

        if (style === "ordered-list") {
            return this.editor.chain().focus().toggleOrderedList().run();
        }

        if (style === "blockquote") {
            return this.editor.chain().focus().toggleBlockquote().run();
        }

        if (style === "code-block") {
            return this.editor.chain().focus().toggleCodeBlock().run();
        }

        if (style === "thematic-break") {
            return this.editor.chain().focus().setHorizontalRule().run();
        }

        return false;
    }

    /** Releases Tiptap resources when the custom element disconnects. */
    public destroy(): void {
        this.editor.destroy();
    }

    /** Handles visual editor keyboard shortcuts that should stay inside the editor. */
    private handleKeyDown(event: KeyboardEvent): boolean {
        if (isPrimaryModifierShortcut(event, "e")) {
            event.preventDefault();
            return this.toggleInlineStyle("code");
        }

        if (isPrimaryModifierShortcut(event, "k")) {
            event.preventDefault();
            this.onLinkShortcut();
            return true;
        }

        // Home/End move to the start/end of the visual line, matching the Markdown (CodeMirror) editor. The
        // contenteditable default on macOS is to scroll the viewport instead, so bind them explicitly; the
        // browser's "lineboundary" granularity respects soft wrapping, and ProseMirror syncs from the DOM
        // selection. Shift extends the selection.
        if (event.key === "Home" || event.key === "End") {
            const selection = window.getSelection();

            if (selection && selection.rangeCount > 0) {
                event.preventDefault();
                selection.modify(
                    event.shiftKey ? "extend" : "move",
                    event.key === "Home" ? "backward" : "forward",
                    "lineboundary",
                );
                return true;
            }

            return false;
        }

        if (event.key !== "Tab") {
            return false;
        }

        event.preventDefault();

        const selection = this.currentVisualSelection();

        if (event.shiftKey) {
            return this.withCurrentSelection(selection, (editor: Editor): boolean =>
                editor.chain().focus().liftListItem("listItem").run(),
            );
        }

        return this.withCurrentSelection(selection, (editor: Editor): boolean =>
            editor.chain().focus().sinkListItem("listItem").run(),
        );
    }

    /** Restores the visual selection before running a toolbar command. */
    /** Shrinks a selection ending at the start of a block back to the end of the previous block. */
    private trimSelectionEndingAtBlockStart(
        selection: { from: number; to: number } | null,
    ): { from: number; to: number } | null {
        if (!selection || selection.from === selection.to) {
            return selection;
        }

        const resolvedTo = this.editor.state.doc.resolve(selection.to);

        if (resolvedTo.parentOffset !== 0 || resolvedTo.depth === 0) {
            return selection;
        }

        const to = resolvedTo.before() - 1;

        return to > selection.from ? { from: selection.from, to } : selection;
    }

    private withCurrentSelection(
        selection: { from: number; to: number } | null,
        command: (editor: Editor) => boolean,
    ): boolean {
        if (selection) {
            this.editor.commands.setTextSelection(selection);
        }

        return command(this.editor);
    }

    /** Converts supported literal list markers into list nodes while typing. */
    private applyListMarkerShortcut(): boolean {
        const text = this.editor.getText();

        if (text === "- ") {
            this.editor.chain().clearContent().toggleBulletList().focus().run();
            return true;
        }

        if (text === "1. ") {
            this.editor.chain().clearContent().toggleOrderedList().focus().run();
            return true;
        }

        return false;
    }

    /** Converts the current browser selection into Tiptap document positions. */
    private currentVisualSelection(): { from: number; to: number } | null {
        const selection = window.getSelection();

        if (!selection?.anchorNode || !selection.focusNode) {
            return null;
        }

        if (!this.root.contains(selection.anchorNode) || !this.root.contains(selection.focusNode)) {
            return null;
        }

        const anchor = this.editor.view.posAtDOM(selection.anchorNode, selection.anchorOffset);
        const focus = this.editor.view.posAtDOM(selection.focusNode, selection.focusOffset);

        return {
            from: Math.min(anchor, focus),
            to: Math.max(anchor, focus),
        };
    }
}

/** Builds an admonition node from an alert-marker blockquote, or null when the blockquote is not an alert. */
function admonitionFromBlockquote(schema: Schema, blockquote: ProseMirrorNode): ProseMirrorNode | null {
    const paragraphType = schema.nodes["paragraph"];
    const admonitionType = schema.nodes["admonition"];
    const firstChild = blockquote.firstChild;

    if (!paragraphType || !admonitionType || !firstChild || firstChild.type.name !== "paragraph") {
        return null;
    }

    const marker = matchAlertMarker(firstChild.textContent);

    if (!marker) {
        return null;
    }

    const bodyNodes: ProseMirrorNode[] = [];
    const leadingParagraph = firstChild.type.create(firstChild.attrs, firstChild.content.cut(marker.length));

    if (leadingParagraph.content.size > 0) {
        bodyNodes.push(leadingParagraph);
    }

    blockquote.content.forEach((child: ProseMirrorNode, _offset: number, index: number): void => {
        if (index > 0) {
            bodyNodes.push(child);
        }
    });

    if (bodyNodes.length === 0) {
        bodyNodes.push(paragraphType.create());
    }

    return admonitionType.create({ kind: marker.kind }, Fragment.fromArray(bodyNodes));
}

/** Checks whether a keyboard event matches a primary-modifier shortcut key. */
function isPrimaryModifierShortcut(event: KeyboardEvent, key: string): boolean {
    return (event.metaKey || event.ctrlKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === key;
}

/** Returns visual editor child blocks that represent Markdown content. */
function editorContentElements(root: HTMLElement): Element[] {
    return Array.from(root.children).filter((element: Element): boolean => !isEmptyParagraphElement(element));
}

/** Checks whether a visual paragraph is only Tiptap's empty trailing block. */
function isEmptyParagraphElement(element: Element): boolean {
    if (element.tagName !== "P" || element.textContent !== "") {
        return false;
    }

    return Array.from(element.childNodes).every(
        (child: ChildNode): boolean => child.nodeType === Node.ELEMENT_NODE && (child as Element).tagName === "BR",
    );
}

/** Returns the first text node inside a rendered visual editor element. */
function firstTextDescendant(node: Node): Text | null {
    if (node instanceof Text) {
        return node;
    }

    for (const child of node.childNodes) {
        const text = firstTextDescendant(child);

        if (text) {
            return text;
        }
    }

    return null;
}

/** Returns the last text node inside a rendered visual editor element. */
function lastTextDescendant(node: Node): Text | null {
    if (node instanceof Text) {
        return node;
    }

    for (const child of Array.from(node.childNodes).reverse()) {
        const text = lastTextDescendant(child);

        if (text) {
            return text;
        }
    }

    return null;
}

/** Converts a `heading-N` toolbar style identifier into its Tiptap heading level. */
function headingLevel(style: Exclude<VisualBlockStyle, "paragraph">): 1 | 2 | 3 | 4 | 5 | 6 {
    return Number(style.slice("heading-".length)) as 1 | 2 | 3 | 4 | 5 | 6;
}

/** Escapes paragraph text that would otherwise be parsed back as Markdown block syntax. */
function escapeLiteralParagraphMarkers(markdown: string, document: JSONContent): string {
    const blocks = markdown.split("\n\n");
    const nodes = document.content ?? [];

    return blocks
        .map((block: string, index: number): string => {
            if (nodes[index]?.type !== "paragraph") {
                return block;
            }

            return block.replace(/^(#{1,6}\s)/u, "\\$1");
        })
        .join("\n\n");
}
