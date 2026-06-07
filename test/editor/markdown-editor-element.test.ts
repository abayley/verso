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

        expect(editor.querySelector(".markdown-editor__source")).toBeInstanceOf(HTMLTextAreaElement);
        expect(editor.querySelector(".markdown-editor__source")?.textContent).toBe("");
        expect((editor.querySelector(".markdown-editor__source") as HTMLTextAreaElement | null)?.value).toBe(
            "<script>alert(1)</script>",
        );
        expect(editor.querySelector(".markdown-editor__error")?.textContent).toBe(
            "Unsupported Markdown node for editor subset: html",
        );
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
        const source = requiredSource(editor);
        source.value = "<script>alert(1)</script>";
        source.dispatchEvent(new Event("input", { bubbles: true }));

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
        const source = requiredSource(editor);
        source.value = "# Recovered";
        source.dispatchEvent(new Event("input", { bubbles: true }));

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

/** Returns the source textarea from a test editor element. */
function requiredSource(editor: Element): HTMLTextAreaElement {
    const source = editor.querySelector(".markdown-editor__source");

    if (!(source instanceof HTMLTextAreaElement)) {
        throw new Error("Expected markdown source textarea.");
    }

    return source;
}
