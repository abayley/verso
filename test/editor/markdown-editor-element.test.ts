import { beforeEach, describe, expect, it } from "vitest";
import { MarkdownEditorElement } from "../../src/TestApp/Editor/markdown-editor-element.js";

const elementName = "markdown-editor-test";

if (!customElements.get(elementName)) {
    customElements.define(elementName, MarkdownEditorElement);
}

describe("MarkdownEditorElement", (): void => {
    beforeEach((): void => {
        document.body.textContent = "";
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
        expect(editor.querySelector(".markdown-editor__preview strong")?.textContent).toBe("strong");
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
    });

    it("given visual mode, when toolbar mode buttons are used, then it switches modes without losing Markdown", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "# Heading\n\nParagraph with **strong** text.";

        document.body.append(editor);
        await waitForInitialisation();

        clickToolbarButton(editor, "Markdown");
        expect(editor.querySelector(".markdown-editor__source .cm-editor")).toBeInstanceOf(HTMLElement);
        expect(editor.toMarkdown()).toContain("# Heading");
        expect(editor.toMarkdown()).toContain("**strong**");

        clickToolbarButton(editor, "Split");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__source .cm-editor")).toBeInstanceOf(
            HTMLElement,
        );
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__preview strong")?.textContent).toBe(
            "strong",
        );

        clickToolbarButton(editor, "Visual");
        expect(editor.querySelector(".markdown-editor__surface .ProseMirror")).toBeInstanceOf(HTMLElement);
        expect(editor.querySelector(".markdown-editor__surface strong")?.textContent).toBe("strong");
    });

    it("given visual mode, when heading style is selected, then the current block becomes a heading", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();

        selectBlockStyle(editor, "heading-2");

        expect(editor.querySelector(".markdown-editor__surface h2")?.textContent).toBe("Plain paragraph");
        expect(editor.querySelector(".markdown-editor__preview h2")?.textContent).toBe("Plain paragraph");
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
        expect(editor.querySelector(".markdown-editor__preview strong")?.textContent).toBe("Plain");
        expect(editor.toMarkdown()).toContain("**Plain** paragraph");
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
        expect(editor.querySelector(".markdown-editor__preview h1")?.textContent).toBe("Recovered");
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
