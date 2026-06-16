import { Editor, type JSONContent, type SetContentOptions } from "@tiptap/core";
import Heading from "@tiptap/extension-heading";
import { Markdown } from "@tiptap/markdown";
import { Fragment, type Node as ProseMirrorNode, type ResolvedPos, type Schema } from "@tiptap/pm/model";
import StarterKit from "@tiptap/starter-kit";
import { type AdmonitionKind, matchAlertMarker } from "./admonition-extension.js";
import { documentFromElements, documentToMarkdown } from "./markdown-serialise.js";
import { Admonition } from "./tiptap-admonition-node.js";
import { tableExtensions } from "./tiptap-table-extensions.js";

/** Callback fired when the visual editor content changes. */
export type TiptapChangeHandler = () => void;

/** Callback fired when the visual editor requests link target input. */
export type TiptapLinkShortcutHandler = () => void;

/** Supported visual block styles exposed by the editor toolbar. */
export type VisualBlockStyle = "paragraph" | "heading-1" | "heading-2" | "heading-3";

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

const HeadingWithoutInputRules = Heading.extend({
    /** Keeps heading nodes available while preventing typed hash shortcuts. */
    addInputRules() {
        return [];
    },
});

/** Markdown-in/Markdown-out adapter around Tiptap's visual editor. */
export class TiptapVisualEditor {
    private readonly editor: Editor;
    private normalisingSoftBreaks = false;
    private readonly onLinkShortcut: TiptapLinkShortcutHandler;
    private readonly root: HTMLDivElement;

    /** Creates a Tiptap editor mounted inside a stable root element. */
    public constructor(markdown: string, onChange: TiptapChangeHandler, onLinkShortcut: TiptapLinkShortcutHandler) {
        this.root = document.createElement("div");
        this.root.className = "markdown-editor__surface";
        this.onLinkShortcut = onLinkShortcut;

        this.editor = new Editor({
            content: markdown,
            contentType: "markdown",
            element: this.root,
            extensions: [
                StarterKit.configure({
                    heading: false,
                }),
                HeadingWithoutInputRules,
                Admonition,
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
        this.upgradeAlertBlockquotes();
        this.collapseSoftBreaks();
    }

    /** Returns the root element that hosts the Tiptap editor. */
    public element(): HTMLDivElement {
        return this.root;
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

        this.editor.commands.setContent(markdown, options);
        this.upgradeAlertBlockquotes();
        this.collapseSoftBreaks();
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

    /** Inserts a 3x3 GFM table with a header row at the current selection. */
    public insertTable(): boolean {
        return this.editor.chain().focus().insertTable({ cols: 3, rows: 3, withHeaderRow: true }).run();
    }

    /** Reports whether the selection is inside a table (for showing the table controls). */
    public isInTable(): boolean {
        return this.editor.isActive("table");
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

    /** Sets the GFM column alignment on the selected table cells. */
    public setColumnAlignment(align: "left" | "center" | "right" | null): boolean {
        return this.editor.chain().focus().setCellAttribute("textAlign", align).run();
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
        if (this.editor.isActive("heading", { level: 1 })) {
            return "heading-1";
        }

        if (this.editor.isActive("heading", { level: 2 })) {
            return "heading-2";
        }

        if (this.editor.isActive("heading", { level: 3 })) {
            return "heading-3";
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

/** Converts toolbar style identifiers into Tiptap heading levels. */
function headingLevel(style: Exclude<VisualBlockStyle, "paragraph">): 1 | 2 | 3 {
    if (style === "heading-1") {
        return 1;
    }

    if (style === "heading-2") {
        return 2;
    }

    return 3;
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
