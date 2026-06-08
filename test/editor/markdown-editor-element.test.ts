import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MarkdownEditorElement } from "../../src/TestApp/Editor/markdown-editor-element.js";

const elementName = "markdown-editor-test";

if (!customElements.get(elementName)) {
    customElements.define(elementName, MarkdownEditorElement);
}

describe("MarkdownEditorElement", (): void => {
    beforeEach((): void => {
        document.body.textContent = "";
    });

    afterEach((): void => {
        vi.restoreAllMocks();
    });

    it("given unsupported source Markdown, when initialised, then it shows a parse error and keeps the source", async (): Promise<void> => {
        const editor = document.createElement(elementName);
        editor.setAttribute("mode", "source");
        editor.textContent = "<script>alert(1)</script>";

        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__source .cm-editor")).toBeInstanceOf(HTMLElement);
        expect((editor as MarkdownEditorElement).toMarkdown()).toBe("<script>alert(1)</script>");
        expect(editor.querySelector(".markdown-editor__error")?.textContent).toBe(
            "Unsupported Markdown node for editor subset: html",
        );
    });

    it("given source mode, when initialised, then it uses CodeMirror and serialises Markdown", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = "# Heading\n\nParagraph with **strong** text.";

        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__source .cm-editor")).toBeInstanceOf(HTMLElement);
        expect(editor.toMarkdown()).toContain("# Heading");
        expect(editor.toMarkdown()).toContain("**strong**");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
    });

    it("given visual mode, when initialised, then it uses Tiptap and serialises Markdown", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "# Heading\n\nParagraph with **strong** text.";

        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__surface .ProseMirror")).toBeInstanceOf(HTMLElement);
        expect(editor.querySelector(".markdown-editor__surface h1")?.textContent).toBe("Heading");
        expect(editor.querySelector(".markdown-editor__surface strong")?.textContent).toBe("strong");
        expect(editor.toMarkdown()).toContain("# Heading");
        expect(editor.toMarkdown()).toContain("**strong**");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
    });

    it("given visual mode, when the mode button is used, then it cycles modes without losing Markdown", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "# Heading\n\nParagraph with **strong** text.";

        document.body.append(editor);
        await waitForInitialisation();

        expect(modeButton(editor).textContent).toBe("Visual");

        modeButton(editor).click();
        expect(editor.querySelector(".markdown-editor__source .cm-editor")).toBeInstanceOf(HTMLElement);
        expect(modeButton(editor).textContent).toBe("Markdown");
        expect(editor.toMarkdown()).toContain("# Heading");
        expect(editor.toMarkdown()).toContain("**strong**");

        modeButton(editor).click();
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__source .cm-editor")).toBeInstanceOf(
            HTMLElement,
        );
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface strong")?.textContent).toBe(
            "strong",
        );
        expect(modeButton(editor).textContent).toBe("Split");

        modeButton(editor).click();
        expect(editor.querySelector(".markdown-editor__surface .ProseMirror")).toBeInstanceOf(HTMLElement);
        expect(editor.querySelector(".markdown-editor__surface strong")?.textContent).toBe("strong");
        expect(modeButton(editor).textContent).toBe("Visual");
    });

    it("given visual mode, when heading style is selected, then the current block becomes a heading", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();

        selectBlockStyle(editor, "heading-2");

        expect(editor.querySelector(".markdown-editor__surface h2")?.textContent).toBe("Plain paragraph");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown().trim()).toBe("## Plain paragraph");
    });

    it("given visual mode, when bold is selected, then the selected text becomes strong", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Bold");

        expect(editor.querySelector(".markdown-editor__surface strong")?.textContent).toBe("Plain");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("**Plain** paragraph");
    });

    it("given visual mode, when italic is selected, then the selected text becomes emphasis", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Italic");

        expect(editor.querySelector(".markdown-editor__surface em")?.textContent).toBe("Plain");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("*Plain* paragraph");
    });

    it("given visual mode, when inline code is selected, then the selected text becomes code", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Code");

        expect(editor.querySelector(".markdown-editor__surface code")?.textContent).toBe("Plain");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("`Plain` paragraph");
    });

    it("given visual mode, when link is selected, then the selected text becomes a link", async (): Promise<void> => {
        vi.stubGlobal(
            "prompt",
            vi.fn((): string => "/target"),
        );
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Link");

        const link = editor.querySelector(".markdown-editor__surface a");
        expect(link?.textContent).toBe("Plain");
        expect(link?.getAttribute("href")).toBe("/target");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("[Plain](/target) paragraph");
    });

    it("given visual mode, when bullet list is selected, then the current block becomes an unordered list", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Bullet List");

        expect(editor.querySelector(".markdown-editor__surface ul li")?.textContent).toBe("Plain paragraph");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("- Plain paragraph");
    });

    it("given visual mode, when ordered list is selected, then the current block becomes an ordered list", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Ordered List");

        expect(editor.querySelector(".markdown-editor__surface ol li")?.textContent).toBe("Plain paragraph");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("1. Plain paragraph");
    });

    it("given visual mode, when blockquote is selected, then the current block becomes a blockquote", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Blockquote");

        expect(editor.querySelector(".markdown-editor__surface blockquote")?.textContent).toBe("Plain paragraph");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("> Plain paragraph");
    });

    it("given split mode, when visual text is styled, then Markdown source is updated", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Split paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Split");

        clickToolbarButton(editor, "Bold");

        expect(editor.querySelector(".markdown-editor__split .markdown-editor__source .cm-editor")).toBeInstanceOf(
            HTMLElement,
        );
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface strong")?.textContent).toBe(
            "Split",
        );
        expect(editor.toMarkdown()).toContain("**Split** paragraph");
    });

    it("given split mode, when Markdown text is selected, then bold applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Bold");

        expect(editor.toMarkdown()).toContain("**Markdown** paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface strong")?.textContent).toBe(
            "Markdown",
        );
    });

    it("given split mode, when Markdown text is selected, then italic applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Italic");

        expect(editor.toMarkdown()).toContain("*Markdown* paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface em")?.textContent).toBe(
            "Markdown",
        );
    });

    it("given split mode, when Markdown text is selected, then code applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Code");

        expect(editor.toMarkdown()).toContain("`Markdown` paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface code")?.textContent).toBe(
            "Markdown",
        );
    });

    it("given split mode, when Markdown text is selected, then link applies to the Markdown source", async (): Promise<void> => {
        vi.stubGlobal(
            "prompt",
            vi.fn((): string => "/target"),
        );
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Link");

        expect(editor.toMarkdown()).toContain("[Markdown](/target) paragraph");
        const link = editor.querySelector(".markdown-editor__split .markdown-editor__surface a");
        expect(link?.textContent).toBe("Markdown");
        expect(link?.getAttribute("href")).toBe("/target");
    });

    it("given split mode, when Markdown text is selected, then bullet list applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Bullet List");

        expect(editor.toMarkdown()).toContain("- Markdown paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface ul li")?.textContent).toBe(
            "Markdown paragraph",
        );
    });

    it("given split mode, when Markdown text is selected, then ordered list applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Ordered List");

        expect(editor.toMarkdown()).toContain("1. Markdown paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface ol li")?.textContent).toBe(
            "Markdown paragraph",
        );
    });

    it("given split mode, when Markdown text is selected, then blockquote applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Blockquote");

        expect(editor.toMarkdown()).toContain("> Markdown paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface blockquote")?.textContent).toBe(
            "Markdown paragraph",
        );
    });

    it("given source mode, when heading style is selected, then the current Markdown line becomes a heading", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        placeSourceCursor(editor, "Plain");

        selectBlockStyle(editor, "heading-2");

        expect(editor.toMarkdown()).toBe("## Plain paragraph");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
    });

    it("given unsupported source Markdown, when edited, then it does not dispatch a changed event", async (): Promise<void> => {
        const editor = document.createElement(elementName);
        editor.setAttribute("mode", "source");
        editor.textContent = "# Heading";
        let changedEvents = 0;
        editor.addEventListener("editor:changed", (): void => {
            changedEvents += 1;
        });

        document.body.append(editor);
        await waitForInitialisation();
        (editor as MarkdownEditorElement).setMarkdown("<script>alert(1)</script>");

        expect(changedEvents).toBe(0);
        expect(editor.querySelector(".markdown-editor__error")?.textContent).toBe(
            "Unsupported Markdown node for editor subset: html",
        );
    });

    it("given a source parse error, when edited to supported Markdown, then it clears the error", async (): Promise<void> => {
        const editor = document.createElement(elementName);
        editor.setAttribute("mode", "source");
        editor.textContent = "<script>alert(1)</script>";

        document.body.append(editor);
        await waitForInitialisation();
        (editor as MarkdownEditorElement).setMarkdown("# Recovered");

        expect((editor.querySelector(".markdown-editor__error") as HTMLElement | null)?.hidden).toBe(true);
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
    });
});

/** Waits for the custom element's asynchronous initialisation timer. */
function waitForInitialisation(): Promise<void> {
    return new Promise((resolve: () => void): void => {
        window.setTimeout(resolve, 0);
    });
}

/** Clicks a toolbar button by its visible label. */
function clickToolbarButton(editor: Element, label: string): void {
    const button = Array.from(editor.querySelectorAll(".markdown-editor__toolbar button")).find(
        (candidate: Element): boolean => candidate.textContent === label,
    );

    if (!(button instanceof HTMLButtonElement)) {
        throw new Error(`Expected toolbar button: ${label}`);
    }

    button.click();
}

/** Returns the single mode cycling toolbar button. */
function modeButton(editor: Element): HTMLButtonElement {
    const button = editor.querySelector(".markdown-editor__mode-button");

    if (!(button instanceof HTMLButtonElement)) {
        throw new Error("Expected toolbar mode button.");
    }

    return button;
}

/** Selects a block style from the toolbar style control. */
function selectBlockStyle(editor: Element, style: string): void {
    const select = editor.querySelector(".markdown-editor__style-select");

    if (!(select instanceof HTMLSelectElement)) {
        throw new Error("Expected toolbar style select.");
    }

    select.value = style;
    select.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Selects matching text inside the visual editor surface. */
function selectText(editor: Element, text: string): void {
    const surface = editor.querySelector(".markdown-editor__surface");

    if (!(surface instanceof HTMLElement)) {
        throw new Error("Expected visual editor surface.");
    }

    const textNode = findTextNode(surface, text);

    if (!textNode) {
        throw new Error(`Expected text node containing: ${text}`);
    }

    const start = textNode.data.indexOf(text);
    const range = document.createRange();
    range.setStart(textNode, start);
    range.setEnd(textNode, start + text.length);

    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
}

/** Finds the first text node containing the requested text. */
function findTextNode(root: Node, text: string): Text | null {
    if (root instanceof Text && root.data.includes(text)) {
        return root;
    }

    for (const child of root.childNodes) {
        const match = findTextNode(child, text);

        if (match) {
            return match;
        }
    }

    return null;
}

/** Selects matching text inside the CodeMirror source editor. */
function selectSourceText(editor: Element, text: string): void {
    const source = editor.querySelector(".markdown-editor__source .cm-content");

    if (!(source instanceof HTMLElement)) {
        throw new Error("Expected source editor content.");
    }

    const textNode = findTextNode(source, text);

    if (!textNode) {
        throw new Error(`Expected source text node containing: ${text}`);
    }

    const start = textNode.data.indexOf(text);
    const range = document.createRange();
    range.setStart(textNode, start);
    range.setEnd(textNode, start + text.length);

    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    source.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
}

/** Places the cursor at the beginning of matching text inside the CodeMirror source editor. */
function placeSourceCursor(editor: Element, text: string): void {
    const source = editor.querySelector(".markdown-editor__source .cm-content");

    if (!(source instanceof HTMLElement)) {
        throw new Error("Expected source editor content.");
    }

    const textNode = findTextNode(source, text);

    if (!textNode) {
        throw new Error(`Expected source text node containing: ${text}`);
    }

    const start = textNode.data.indexOf(text);
    const range = document.createRange();
    range.setStart(textNode, start);
    range.collapse(true);

    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    source.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
}
