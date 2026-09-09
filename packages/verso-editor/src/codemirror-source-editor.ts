import { markdown } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorState, Prec } from "@codemirror/state";
import { tags } from "@lezer/highlight";
import { basicSetup, EditorView } from "codemirror";
import { fenceHighlighting } from "./codemirror-fence-highlight.js";
import type { EditingCommand, EditingSurface, VisualBlockStyle } from "./editing-surface.js";
import { headingLineNumbers } from "./table-of-contents.js";

type InlineEditingCommand = Extract<EditingCommand, { kind: "toggle-inline-style" }>;
type StructureEditingCommand = Extract<EditingCommand, { kind: "toggle-structure" }>;
type InsertStructureCommand = Extract<EditingCommand, { kind: "insert-structure" }>;

// Syntax highlighting driven by the editor's palette CSS variables, so the Markdown source reads correctly
// in both light and dark mode (the variables flip under :root.dark). It overrides CodeMirror's default
// light-oriented highlight style -- which was unreadable on the dark background -- via Prec.highest.
const paletteHighlightStyle = HighlightStyle.define([
    { tag: tags.heading, color: "var(--markdown-editor-accent)", fontWeight: "600" },
    { tag: tags.strong, color: "var(--markdown-editor-text)", fontWeight: "600" },
    { tag: tags.emphasis, color: "var(--markdown-editor-text)", fontStyle: "italic" },
    { tag: tags.strikethrough, textDecoration: "line-through" },
    { tag: [tags.link, tags.url], color: "var(--markdown-editor-accent)" },
    { tag: [tags.monospace, tags.literal], color: "var(--markdown-editor-info)" },
    { tag: tags.quote, color: "var(--markdown-editor-muted)", fontStyle: "italic" },
    {
        tag: [tags.list, tags.meta, tags.processingInstruction, tags.contentSeparator],
        color: "var(--markdown-editor-muted)",
    },
]);

/** Callback fired when the source editor content changes. */
export type CodeMirrorChangeHandler = () => void;

/** Callback fired when the source editor requests link target input. */
export type CodeMirrorLinkShortcutHandler = () => void;

export interface CodeMirrorSourceSelection {
    from: number;
    to: number;
}

/** Markdown source editor adapter around CodeMirror. */
export class CodeMirrorSourceEditor implements EditingSurface {
    private readonly root: HTMLDivElement;
    private readonly view: EditorView;
    private readonly onLinkShortcut: CodeMirrorLinkShortcutHandler;

    /** Creates a CodeMirror editor mounted inside a stable root element. */
    public constructor(
        markdownText: string,
        onChange: CodeMirrorChangeHandler,
        onLinkShortcut: CodeMirrorLinkShortcutHandler,
        options: { editable?: boolean } = {},
    ) {
        this.root = document.createElement("div");
        this.root.className = "markdown-editor__source";
        this.onLinkShortcut = onLinkShortcut;
        const editable = options.editable ?? true;

        this.view = new EditorView({
            doc: markdownText,
            extensions: [
                basicSetup,
                // Before the palette within the same precedence: equal-precedence extensions keep
                // their order, and an earlier decoration source nests INSIDE a later one -- the hljs
                // token marks must sit inside the palette's blanket literal (blue) span to colour
                // fence bodies at all.
                Prec.highest(fenceHighlighting()),
                Prec.highest(syntaxHighlighting(paletteHighlightStyle)),
                markdown(),
                EditorView.lineWrapping,
                // Read-only source view (RFC-0020): block edits and the editing affordance.
                EditorState.readOnly.of(!editable),
                EditorView.editable.of(editable),
                EditorView.domEventHandlers({
                    keydown: (event: KeyboardEvent): boolean => this.handleKeyDown(event),
                }),
                EditorView.updateListener.of((update): void => {
                    if (update.docChanged) {
                        onChange();
                    }
                }),
            ],
            parent: this.root,
        });
    }

    /** Returns the root element that hosts the CodeMirror editor. */
    public element(): HTMLDivElement {
        return this.root;
    }

    /** Scrolls (and moves the caret) to the n-th heading line -- the contents panel's click target. */
    public scrollToHeading(index: number): void {
        const lineNumber = headingLineNumbers(this.view.state.doc.toString())[index];

        if (lineNumber === undefined) {
            return;
        }

        const line = this.view.state.doc.line(lineNumber + 1);
        this.view.dispatch({
            effects: EditorView.scrollIntoView(line.from, { y: "start" }),
            selection: { anchor: line.from },
        });
        this.view.focus();
    }

    /**
     * The viewport top of every heading line, in the same order as the contents entries, for the panel's
     * reading indicator. Taken from CodeMirror's height map rather than `coordsAtPos`, which is null for
     * anything outside the rendered window -- most of a long document. Heights outside that window are
     * estimated, which is accurate enough to say which section is on screen.
     */
    public headingViewportTops(): number[] {
        const doc = this.view.state.doc;
        const contentTop = this.view.contentDOM.getBoundingClientRect().top;

        return headingLineNumbers(doc.toString()).map((line: number): number => {
            const position = doc.line(line + 1).from;

            return contentTop + this.view.lineBlockAt(position).top;
        });
    }

    /** The 1-based line and column of the caret (the selection head), for the status bar. */
    public cursorPosition(): { line: number; column: number } {
        const head = this.view.state.selection.main.head;
        const line = this.view.state.doc.lineAt(head);

        return { column: head - line.from + 1, line: line.number };
    }

    /** Replaces the current source document. */
    public setMarkdown(markdownText: string): void {
        this.view.dispatch({
            changes: {
                from: 0,
                insert: markdownText,
                to: this.view.state.doc.length,
            },
        });
    }

    /** Applies a semantic editing command using CodeMirror transactions. */
    public applyCommand(command: EditingCommand): boolean {
        switch (command.kind) {
            case "apply-block-style":
                return this.applyBlockStyle(command.style);
            case "toggle-inline-style":
                return this.toggleInlineCommand(command.style, command.href);
            case "toggle-structure":
                return this.toggleStructureCommand(command.style);
            case "apply-badge":
                return this.applyBadge(command.colour);
            case "remove-badge":
            case "remove-link":
                return false;
            case "insert-structure":
                return this.insertMarkdown(sourceStructureMarkdown(command));
            case "insert-mermaid":
                return this.insertMarkdown("```mermaid\ngraph TD\n    A --> B\n```\n");
            case "insert-attachment":
                return this.insertMarkdown(
                    command.image ? `![${command.text}](${command.url})` : `[${command.text}](${command.url})`,
                );
            case "set-link":
                return command.selection
                    ? this.toggleLinkAt(command.selection, command.href)
                    : this.toggleLink(command.href);
        }
    }

    /** Routes an inline command to its CodeMirror implementation. */
    private toggleInlineCommand(style: InlineEditingCommand["style"], href?: string): boolean {
        switch (style) {
            case "strong":
                return this.toggleStrong();
            case "emphasis":
                return this.toggleEmphasis();
            case "code":
                return this.toggleCode();
            case "strikethrough":
                return this.toggleStrikethrough();
            case "link":
                return href ? this.toggleLink(href) : false;
        }
    }

    /** Routes a structure command to its CodeMirror implementation. */
    private toggleStructureCommand(style: StructureEditingCommand["style"]): boolean {
        switch (style) {
            case "bullet-list":
                return this.toggleBulletList();
            case "ordered-list":
                return this.toggleOrderedList();
            case "blockquote":
                return this.toggleBlockquote();
            case "code-block":
                return this.insertCodeBlock();
            case "thematic-break":
                return this.insertThematicBreak();
        }
    }

    /** Applies a block style to the source line containing the cursor. */
    public applyBlockStyle(style: VisualBlockStyle): boolean {
        const selection = this.currentSourceSelection();
        const line = this.view.state.doc.lineAt(selection?.to ?? this.view.state.selection.main.head);
        const lineText = line.text.replace(/^#{1,6}\s+/, "");
        const replacement = style === "paragraph" ? lineText : `${headingPrefix(style)} ${lineText}`;

        this.view.dispatch({
            changes: {
                from: line.from,
                insert: replacement,
                to: line.to,
            },
        });

        return true;
    }

    /** Toggles Markdown strong markers around the current source selection. */
    public toggleStrong(): boolean {
        return this.wrapSelection("**", "**");
    }

    /** Toggles Markdown emphasis markers around the current source selection. */
    public toggleEmphasis(): boolean {
        return this.wrapSelection("*", "*");
    }

    /** Toggles Markdown inline code markers around the current source selection. */
    public toggleCode(): boolean {
        const selection = this.trimSelectionEndingAtLineStart(this.currentSourceSelection());

        if (!selection || selection.from === selection.to) {
            return false;
        }

        if (this.selectedText(selection).includes("\n")) {
            return this.insertCodeBlockAt(selection);
        }

        return this.wrapSourceSelection(selection, "`", "`");
    }

    /** Toggles Markdown strikethrough markers around the current source selection. */
    public toggleStrikethrough(): boolean {
        return this.wrapSelection("~~", "~~");
    }

    /** Wraps the current source selection as a badge lozenge: `` `selection`{.badge.<colour>} `` (RFC-0021). */
    public applyBadge(colour: string): boolean {
        return this.wrapSelection("`", `\`{.badge.${colour}}`);
    }

    /** Toggles Markdown link markers around the current source selection. */
    public toggleLink(href: string): boolean {
        return this.wrapSelection("[", `](${href})`);
    }

    /** Returns the current source selection as CodeMirror document offsets. */
    public currentSelection(): CodeMirrorSourceSelection | null {
        return this.currentSourceSelection();
    }

    /** Selects a source range and focuses CodeMirror. */
    public select(from: number, to: number): void {
        this.view.dispatch({ selection: { anchor: from, head: to }, scrollIntoView: true });
        this.view.focus();
    }

    /** Places the source caret at a document position. */
    public caretAt(position: number): void {
        this.select(position, position);
    }

    /** Toggles Markdown link markers around a previously captured source selection. */
    public toggleLinkAt(selection: CodeMirrorSourceSelection, href: string): boolean {
        return this.wrapSourceSelection(selection, "[", `](${href})`);
    }

    /** Toggles a Markdown unordered-list marker on the current source line. */
    public toggleBulletList(): boolean {
        return this.toggleLinePrefix(/^[-*+] /, "- ");
    }

    /** Toggles a Markdown ordered-list marker on the current source line. */
    public toggleOrderedList(): boolean {
        return this.toggleLinePrefix(/^\d+\. /, "1. ");
    }

    /** Toggles a Markdown blockquote marker on the current source line. */
    public toggleBlockquote(): boolean {
        return this.toggleLinePrefix(/^> /, "> ");
    }

    /** Wraps the source selection, or current line, in a Markdown fenced code block. */
    public insertCodeBlock(): boolean {
        const selection = this.trimSelectionEndingAtLineStart(this.currentSourceSelection());

        if (selection && selection.from !== selection.to) {
            return this.insertCodeBlockAt(selection);
        }

        return this.replaceCurrentLine(["```", this.currentLineText(), "```"].join("\n"));
    }

    /** Wraps a known source selection in a Markdown fenced code block. */
    private insertCodeBlockAt(selection: CodeMirrorSourceSelection): boolean {
        this.view.dispatch({
            changes: {
                from: selection.from,
                insert: ["```", this.selectedText(selection), "```"].join("\n"),
                to: selection.to,
            },
        });

        return true;
    }

    /** Shrinks a selection ending at the start of a line back past that line's leading newline. */
    private trimSelectionEndingAtLineStart(
        selection: CodeMirrorSourceSelection | null,
    ): CodeMirrorSourceSelection | null {
        if (!selection || selection.from === selection.to) {
            return selection;
        }

        const endLine = this.view.state.doc.lineAt(selection.to);

        if (selection.to !== endLine.from) {
            return selection;
        }

        return { from: selection.from, to: selection.to - 1 };
    }

    /** Replaces the current source line with a Markdown thematic break. */
    public insertThematicBreak(): boolean {
        return this.replaceCurrentLine("---");
    }

    /** Inserts literal Markdown at the caret (replacing any selection) and places the caret after it. */
    public insertMarkdown(markdownText: string): boolean {
        const selection = this.currentSourceSelection();
        const from = selection?.from ?? this.view.state.selection.main.from;
        const to = selection?.to ?? this.view.state.selection.main.to;

        this.view.dispatch({
            changes: { from, insert: markdownText, to },
            selection: { anchor: from + markdownText.length },
        });

        return true;
    }

    /** Handles source editor keyboard shortcuts that should not leave the editor. */
    private handleKeyDown(event: KeyboardEvent): boolean {
        if (isPrimaryModifierShortcut(event, "b")) {
            event.preventDefault();
            return this.toggleStrong();
        }

        if (isPrimaryModifierShortcut(event, "i")) {
            event.preventDefault();
            return this.toggleEmphasis();
        }

        if (isPrimaryModifierShortcut(event, "e")) {
            event.preventDefault();
            return this.toggleCode();
        }

        if (isPrimaryModifierShortcut(event, "s", { shiftKey: true })) {
            event.preventDefault();
            return this.toggleStrikethrough();
        }

        if (isPrimaryModifierShortcut(event, "k")) {
            event.preventDefault();
            this.onLinkShortcut();
            return true;
        }

        if (event.key !== "Tab") {
            return false;
        }

        event.preventDefault();

        if (event.shiftKey) {
            this.outdentCurrentLine();
        } else {
            this.indentCurrentLine();
        }

        return true;
    }

    /** Adds one Markdown indentation level to the current source line. */
    private indentCurrentLine(): void {
        const line = this.view.state.doc.lineAt(this.view.state.selection.main.head);

        this.view.dispatch({
            changes: {
                from: line.from,
                insert: "    ",
            },
        });
    }

    /** Removes up to one Markdown indentation level from the current source line. */
    private outdentCurrentLine(): void {
        const line = this.view.state.doc.lineAt(this.view.state.selection.main.head);
        const indentationWidth = Math.min(line.text.match(/^ */)?.[0].length ?? 0, 4);

        if (indentationWidth === 0) {
            return;
        }

        this.view.dispatch({
            changes: {
                from: line.from,
                to: line.from + indentationWidth,
            },
        });
    }

    /** Toggles a Markdown line prefix on the current source line. */
    private toggleLinePrefix(markerPattern: RegExp, marker: string): boolean {
        const selection = this.currentSourceSelection();
        const line = this.view.state.doc.lineAt(selection?.to ?? this.view.state.selection.main.head);
        const replacement = line.text.match(markerPattern)
            ? line.text.replace(markerPattern, "")
            : `${marker}${line.text}`;

        this.view.dispatch({
            changes: {
                from: line.from,
                insert: replacement,
                to: line.to,
            },
        });

        return true;
    }

    /** Replaces the current source line with Markdown text. */
    private replaceCurrentLine(markdownText: string): boolean {
        const selection = this.currentSourceSelection();
        const line = this.view.state.doc.lineAt(selection?.to ?? this.view.state.selection.main.head);

        this.view.dispatch({
            changes: {
                from: line.from,
                insert: markdownText,
                to: line.to,
            },
        });

        return true;
    }

    /** Returns the current source line text. */
    private currentLineText(): string {
        const selection = this.currentSourceSelection();
        const line = this.view.state.doc.lineAt(selection?.to ?? this.view.state.selection.main.head);

        return line.text;
    }

    /** Serialises the current source document to Markdown. */
    public toMarkdown(): string {
        return this.view.state.doc.toString();
    }

    /** Releases CodeMirror resources when the source editor is removed. */
    public destroy(): void {
        this.view.destroy();
    }

    /** Wraps the current source selection with Markdown marker text. */
    private wrapSelection(prefix: string, suffix: string): boolean {
        const selection = this.currentSourceSelection();

        if (!selection || selection.from === selection.to) {
            return false;
        }

        return this.wrapSourceSelection(selection, prefix, suffix);
    }

    /** Wraps a known source selection with Markdown marker text. */
    private wrapSourceSelection(selection: CodeMirrorSourceSelection, prefix: string, suffix: string): boolean {
        const selectedText = this.selectedText(selection);
        this.view.dispatch({
            changes: {
                from: selection.from,
                insert: `${prefix}${selectedText}${suffix}`,
                to: selection.to,
            },
        });

        return true;
    }

    /** Returns the Markdown source covered by a known selection. */
    private selectedText(selection: CodeMirrorSourceSelection): string {
        return this.view.state.doc.sliceString(selection.from, selection.to);
    }

    /** Converts the current browser selection into CodeMirror document positions. */
    private currentSourceSelection(): CodeMirrorSourceSelection | null {
        const selection = window.getSelection();

        if (!selection?.anchorNode || !selection.focusNode) {
            return null;
        }

        if (!this.root.contains(selection.anchorNode) || !this.root.contains(selection.focusNode)) {
            return null;
        }

        const anchor = this.view.posAtDOM(selection.anchorNode, selection.anchorOffset);
        const focus = this.view.posAtDOM(selection.focusNode, selection.focusOffset);

        return {
            from: Math.min(anchor, focus),
            to: Math.max(anchor, focus),
        };
    }
}

/** Serialises a semantic block insertion into its source-mode Markdown form. */
function sourceStructureMarkdown(command: InsertStructureCommand): string {
    if (command.structure === "table") {
        return "| Column | Column |\n| --- | --- |\n| Cell | Cell |\n";
    }

    if (command.structure === "gfm-alert") {
        return `> [!${(command.gfmAlertKind ?? "note").toUpperCase()}]\n> Text\n`;
    }

    return `??? ${command.collapsibleKind ?? "note"} "Title"\n    Text\n`;
}

/** Converts a `heading-N` toolbar style identifier into its Markdown heading prefix. */
function headingPrefix(style: Exclude<VisualBlockStyle, "paragraph">): string {
    return "#".repeat(Number(style.slice("heading-".length)));
}

interface PrimaryModifierShortcutOptions {
    shiftKey?: boolean;
}

/** Checks whether a keyboard event matches a primary-modifier shortcut key. */
function isPrimaryModifierShortcut(
    event: KeyboardEvent,
    key: string,
    options: PrimaryModifierShortcutOptions = {},
): boolean {
    return (
        (event.metaKey || event.ctrlKey) &&
        !event.altKey &&
        Boolean(event.shiftKey) === Boolean(options.shiftKey) &&
        event.key.toLowerCase() === key
    );
}
