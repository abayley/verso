import type { Editor } from "@tiptap/core";
import type { Node as ProseMirrorNode } from "@tiptap/pm/model";
import type { EditorView } from "@tiptap/pm/view";
import { type ChromeDropdownElement, chromeDropdownEl, chromeIconEl } from "./chrome.js";
import { loadMermaid } from "./mermaid-loader.js";

/** The label shown for a code block with no language set (a plain, unhighlighted block). */
const PLAIN_LABEL = "Plain text";

/** The fence language that renders as a diagram rather than highlighted source (RFC-0033). */
const MERMAID_LANGUAGE = "mermaid";

/** Debounce for re-rendering a diagram after its source changes, in milliseconds. */
const RENDER_DEBOUNCE_MS = 250;

/** A process-wide counter giving each Mermaid render a unique element id (Mermaid requires one per render). */
let mermaidRenderSeq = 0;

/** A process-wide counter giving each code-block language picker a unique dropdown id. */
let codeBlockPickerSeq = 0;

/** Whether the page is currently in the dark colour scheme (drives the Mermaid theme). */
function isDarkScheme(): boolean {
    return document.documentElement.classList.contains("dark");
}

/**
 * The NodeView for the fenced-code-block node (RFC-0033). It keeps the code-block DOM shape — a `<pre>` root
 * with a `<code class="language-...">` content element — so both the serialiser (`codeBlockFromElement`, which
 * keys on `tagName === "PRE"` and reads `code.textContent`) and CodeBlockLowlight's decoration plugin keep
 * working unchanged. On top of that content it adds a language picker (edit view) / language label (read
 * view), and, for a `mermaid` fence, renders the diagram: source is shown only while the node is focused in
 * the edit view; otherwise (unfocused, or the read view) the diagram is shown in its place.
 */
export class CodeBlockView {
    public readonly dom: HTMLPreElement;
    public readonly contentDOM: HTMLElement;
    private readonly toolbar: HTMLDivElement;
    private readonly picker: ChromeDropdownElement;
    private readonly label: HTMLElement;
    private readonly copyButton: HTMLButtonElement;
    private copyTimer: ReturnType<typeof setTimeout> | null = null;
    private readonly diagram: HTMLDivElement;
    private node: ProseMirrorNode;
    private readonly editor: Editor;
    private readonly getPos: () => number | undefined;
    private readonly languages: readonly string[];
    private focused = false;
    private renderedDiagramSource: string | null = null;
    private renderTimer: ReturnType<typeof setTimeout> | null = null;
    private readonly onSelectionUpdate: () => void;
    private readonly schemeObserver: MutationObserver;

    public constructor(
        node: ProseMirrorNode,
        editor: Editor,
        getPos: () => number | undefined,
        languages: readonly string[],
    ) {
        this.node = node;
        this.editor = editor;
        this.getPos = getPos;
        this.languages = languages;

        this.dom = document.createElement("pre");
        this.toolbar = document.createElement("div");
        this.toolbar.className = "markdown-editor__code-toolbar";
        this.toolbar.contentEditable = "false";
        this.label = document.createElement("span");
        this.label.className = "markdown-editor__code-language";
        this.picker = this.createPicker();
        this.copyButton = document.createElement("button");
        this.copyButton.type = "button";
        this.copyButton.className = "markdown-editor__code-copy";
        this.copyButton.title = "Copy code";
        this.copyButton.setAttribute("aria-label", "Copy code");
        this.copyButton.append(chromeIconEl("copy"));
        this.copyButton.addEventListener("click", (): void => void this.copyCode());
        this.toolbar.append(this.picker, this.label, this.copyButton);

        this.contentDOM = document.createElement("code");
        this.diagram = document.createElement("div");
        this.diagram.className = "markdown-editor__mermaid";
        this.diagram.contentEditable = "false";
        // Clicking a rendered diagram moves the caret into the source so it can be edited (the SVG itself is
        // not editable, so this is how a pointer user reveals the source).
        this.diagram.addEventListener("mousedown", (event: Event): void => this.enterSource(event));

        this.dom.append(this.toolbar, this.contentDOM, this.diagram);

        this.focused = this.selectionInside();
        this.onSelectionUpdate = (): void => this.handleSelectionUpdate();
        this.editor.on("selectionUpdate", this.onSelectionUpdate);
        // Re-render diagrams when the light/dark scheme flips live (Mermaid bakes the theme into the SVG).
        this.schemeObserver = new MutationObserver((): void => this.handleSchemeChange());
        this.schemeObserver.observe(document.documentElement, { attributeFilter: ["class"] });

        this.render();
    }

    /** Builds the Basecoat language dropdown; selecting an item sets the node's language attribute. */
    private createPicker(): ChromeDropdownElement {
        codeBlockPickerSeq += 1;
        const dropdown = chromeDropdownEl({
            id: `code-language-${codeBlockPickerSeq}`,
            className: "markdown-editor__code-language-dropdown",
            intent: "quiet",
            triggerLabel: PLAIN_LABEL,
            triggerClassName: "markdown-editor__button markdown-editor__code-language-trigger",
            ariaLabel: "Code language",
            // The picker rides inside the block's <pre>, which scrolls its own overflow: unpinned, the menu
            // is clipped by the block (badly, on a one-line fence) and its closed height gives the block a
            // scrollbar over nothing.
            pinned: true,
            deferred: true,
            items: [
                { value: "", label: PLAIN_LABEL },
                { value: MERMAID_LANGUAGE, label: "Mermaid" },
                ...this.languages.map((lang) => ({ value: lang, label: lang })),
            ],
            onSelect: (value: string): void => this.setLanguage(value),
        });

        return dropdown;
    }

    /** Sets the code block's `language` attribute at this node's position. */
    private setLanguage(language: string): void {
        const pos = this.getPos();

        if (pos === undefined) {
            return;
        }

        const view: EditorView = this.editor.view;
        const attrs = { ...this.node.attrs, language: language || null };
        view.dispatch(view.state.tr.setNodeMarkup(pos, undefined, attrs));
        this.editor.commands.focus();
    }

    /** The node's language, or the empty string for a plain block. */
    private language(): string {
        return typeof this.node.attrs["language"] === "string" ? this.node.attrs["language"] : "";
    }

    /** Whether this is a Mermaid fence (rendered as a diagram rather than highlighted source). */
    private isMermaid(): boolean {
        return this.language() === MERMAID_LANGUAGE;
    }

    /** Whether the editor selection currently sits inside this node. */
    private selectionInside(): boolean {
        const pos = this.getPos();

        if (pos === undefined) {
            return false;
        }

        const { from } = this.editor.state.selection;

        return from >= pos && from <= pos + this.node.nodeSize;
    }

    /** On a selection change, re-render if the focus state of this node flipped (source vs diagram). */
    private handleSelectionUpdate(): void {
        const inside = this.selectionInside();

        if (inside !== this.focused) {
            this.focused = inside;
            this.render();
        }
    }

    /** On a live scheme change, re-render the diagram (only meaningful while it is shown). */
    private handleSchemeChange(): void {
        if (this.isMermaid() && !this.diagram.hidden) {
            this.renderedDiagramSource = null;
            this.renderDiagram();
        }
    }

    /** Copies the block's source to the clipboard, flashing a check icon as confirmation. */
    private async copyCode(): Promise<void> {
        try {
            await navigator.clipboard.writeText(this.node.textContent);
        } catch {
            return; // clipboard unavailable (permissions / insecure context): leave the button as-is
        }

        this.copyButton.replaceChildren(chromeIconEl("check"));
        this.copyButton.setAttribute("aria-label", "Copied");
        this.copyButton.dataset["copied"] = "true";

        if (this.copyTimer !== null) {
            clearTimeout(this.copyTimer);
        }

        this.copyTimer = setTimeout((): void => {
            this.copyButton.replaceChildren(chromeIconEl("copy"));
            this.copyButton.setAttribute("aria-label", "Copy code");
            delete this.copyButton.dataset["copied"];
            this.copyTimer = null;
        }, 1500);
    }

    /** Moves the caret into the source so a Mermaid diagram can be edited. */
    private enterSource(event: Event): void {
        const pos = this.getPos();

        if (pos === undefined || !this.editor.isEditable) {
            return;
        }

        event.preventDefault();
        this.editor
            .chain()
            .setTextSelection(pos + 1)
            .focus()
            .run();
    }

    /** Reflects the current language, edit/read state, and Mermaid mode onto the DOM. */
    private render(): void {
        const language = this.language();
        this.contentDOM.className = language ? `language-${language}` : "";
        const triggerLabel = this.isMermaid() ? "Mermaid" : language || PLAIN_LABEL;
        this.picker.setTriggerLabel(triggerLabel);
        this.picker.syncChecked(language);

        this.label.textContent = triggerLabel;
        const editable = this.editor.isEditable;
        this.picker.style.display = editable ? "" : "none";
        this.label.hidden = editable;

        // Mermaid: show the source only while editing this node; otherwise show the diagram in its place.
        const showDiagram = this.isMermaid() && !(editable && this.focused);
        this.contentDOM.hidden = showDiagram;
        this.diagram.hidden = !showDiagram;

        if (showDiagram) {
            this.renderDiagram();
        }
    }

    /** Renders (or re-renders) the Mermaid diagram from the current source, debounced, into the diagram area. */
    private renderDiagram(): void {
        const source = this.node.textContent.trim();

        if (source === this.renderedDiagramSource) {
            return;
        }

        if (this.renderTimer !== null) {
            clearTimeout(this.renderTimer);
        }

        if (source.length === 0) {
            this.renderedDiagramSource = "";
            this.diagram.textContent = "Empty diagram.";
            this.diagram.classList.add("markdown-editor__mermaid--empty");

            return;
        }

        this.renderTimer = setTimeout((): void => {
            this.renderedDiagramSource = source;
            mermaidRenderSeq += 1;
            const id = `verso-mermaid-${mermaidRenderSeq}`;
            loadMermaid()
                .then(
                    (mermaid): Promise<void> =>
                        mermaid.render(id, source, isDarkScheme()).then((result): void => {
                            // A stale render (the source changed again while awaiting) is discarded.
                            if (this.renderedDiagramSource !== source) {
                                return;
                            }

                            if (typeof result.svg === "string") {
                                this.diagram.innerHTML = result.svg;
                                this.diagram.classList.remove(
                                    "markdown-editor__mermaid--empty",
                                    "markdown-editor__mermaid--error",
                                );
                            } else {
                                this.showDiagramError(result.error ?? "Could not render diagram.");
                            }
                        }),
                )
                .catch((): void => {
                    // Bundle load / engine failure: fall back to a notice; the source stays intact and editable.
                    this.renderedDiagramSource = null;
                    this.showDiagramError("Could not load the diagram renderer.");
                });
        }, RENDER_DEBOUNCE_MS);
    }

    /** Shows an error message in the diagram area (a syntax error or a renderer failure). */
    private showDiagramError(message: string): void {
        this.diagram.textContent = message;
        this.diagram.classList.add("markdown-editor__mermaid--error");
        this.diagram.classList.remove("markdown-editor__mermaid--empty");
    }

    /** Keeps the NodeView on attribute/content changes to the same node type (so decorations re-apply). */
    public update(node: ProseMirrorNode): boolean {
        if (node.type !== this.node.type) {
            return false;
        }

        this.node = node;
        this.render();

        return true;
    }

    /** Chrome (toolbar, diagram) is not editor content: never treat its mutations as document changes. */
    public ignoreMutation(mutation: MutationRecord | { type: "selection"; target: Node }): boolean {
        if (mutation.type === "selection") {
            return false;
        }

        return !this.contentDOM.contains(mutation.target as Node);
    }

    /** Let the picker and diagram handle their own pointer/keyboard events rather than the editor. */
    public stopEvent(event: Event): boolean {
        return this.toolbar.contains(event.target as Node) || this.diagram.contains(event.target as Node);
    }

    /** Detaches listeners when the NodeView is torn down. */
    public destroy(): void {
        this.editor.off("selectionUpdate", this.onSelectionUpdate);
        this.schemeObserver.disconnect();

        if (this.renderTimer !== null) {
            clearTimeout(this.renderTimer);
        }

        if (this.copyTimer !== null) {
            clearTimeout(this.copyTimer);
        }
    }
}
