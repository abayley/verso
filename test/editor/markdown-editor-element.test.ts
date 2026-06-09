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
        vi.useRealTimers();
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

    it("given source mode with a quoted list item containing code, when initialised, then it accepts the Markdown", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = [
            "> 1. xxx",
            "> 2. yyy",
            ">    ",
            ">    ```typescript",
            ">    export type EditorBlock = BlockquoteBlock | CodeBlock | HeadingBlock | HorizontalRuleBlock | ListBlock | ParagraphBlock;",
            ">    ```",
        ].join("\n");

        document.body.append(editor);
        await waitForInitialisation();

        expect((editor.querySelector(".markdown-editor__error") as HTMLElement | null)?.hidden).toBe(true);
        expect(editor.toMarkdown()).toContain("export type EditorBlock");
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

    it("given visual mode, when mode radio options are selected, then it changes modes without losing Markdown", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "# Heading\n\nParagraph with **strong** text.";

        document.body.append(editor);
        await waitForInitialisation();

        expect(modeControl(editor).getAttribute("value")).toBe("visual");

        selectMode(editor, "source");
        expect(editor.querySelector(".markdown-editor__source .cm-editor")).toBeInstanceOf(HTMLElement);
        expect(modeControl(editor).getAttribute("value")).toBe("source");
        expect(editor.toMarkdown()).toContain("# Heading");
        expect(editor.toMarkdown()).toContain("**strong**");

        selectMode(editor, "split");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__source .cm-editor")).toBeInstanceOf(
            HTMLElement,
        );
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface strong")?.textContent).toBe(
            "strong",
        );
        expect(modeControl(editor).getAttribute("value")).toBe("split");

        selectMode(editor, "visual");
        expect(editor.querySelector(".markdown-editor__surface .ProseMirror")).toBeInstanceOf(HTMLElement);
        expect(editor.querySelector(".markdown-editor__surface strong")?.textContent).toBe("strong");
        expect(modeControl(editor).getAttribute("value")).toBe("visual");
    });

    it("given toolbar controls, when scanning across buttons, then the shared tooltip retargets before hiding", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        vi.useFakeTimers();

        const boldButton = toolbarButton(editor, "Bold");
        const italicButton = toolbarButton(editor, "Italic");
        const tooltip = toolbarTooltip(editor);

        boldButton.dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));

        expect(tooltip.hasAttribute("open")).toBe(false);

        vi.advanceTimersByTime(499);

        expect(tooltip.hasAttribute("open")).toBe(false);

        vi.advanceTimersByTime(1);

        expect(tooltip.hasAttribute("open")).toBe(true);
        expect(tooltip.getAttribute("for")).toBe(boldButton.id);
        expect(tooltip.textContent).toBe(`Bold (${primaryModifierLabel()}+B)`);

        boldButton.dispatchEvent(new PointerEvent("pointerout", { bubbles: true }));
        italicButton.dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));

        expect(tooltip.hasAttribute("open")).toBe(true);
        expect(tooltip.getAttribute("for")).toBe(italicButton.id);
        expect(tooltip.textContent).toBe(`Italic (${primaryModifierLabel()}+I)`);

        italicButton.dispatchEvent(new PointerEvent("pointerout", { bubbles: true }));

        vi.advanceTimersByTime(249);

        expect(tooltip.hasAttribute("open")).toBe(true);

        vi.advanceTimersByTime(1);

        expect(tooltip.hasAttribute("open")).toBe(false);
    });

    it("given source mode with a list item containing a blockquote, when cycled through split to visual, then Markdown nesting is preserved", async (): Promise<void> => {
        const markdown = ["- > # blockquote heading 1", "  >", "  > paragraph 1"].join("\n");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = markdown;

        document.body.append(editor);
        await waitForInitialisation();

        selectMode(editor, "split");
        expect(modeControl(editor).getAttribute("value")).toBe("split");
        selectMode(editor, "visual");
        expect(modeControl(editor).getAttribute("value")).toBe("visual");

        expect(editor.toMarkdown()).toBe(markdown);
    });

    it("given source mode with a blockquote containing a spread ordered list, when cycled through split to visual, then Markdown nesting is preserved", async (): Promise<void> => {
        const markdown = [
            "> 1. item 1",
            "> 2. item 2",
            ">    ",
            ">    ```shell",
            ">    ls -al",
            ">    ps -ef",
            ">    ```",
            ">",
            "> 3. item 3",
        ].join("\n");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = markdown;

        document.body.append(editor);
        await waitForInitialisation();

        selectMode(editor, "split");
        expect(modeControl(editor).getAttribute("value")).toBe("split");
        selectMode(editor, "visual");
        expect(modeControl(editor).getAttribute("value")).toBe("visual");

        expect(editor.toMarkdown()).toBe(markdown);
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

    it("given visual mode, when strike is selected, then the selected text becomes strikethrough", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Strike");

        expect(editor.querySelector(".markdown-editor__surface del, .markdown-editor__surface s")?.textContent).toBe(
            "Plain",
        );
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("~~Plain~~ paragraph");
    });

    it("given visual mode, when link target is applied, then the selected text becomes a link", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Link");
        applyLinkTarget(editor, "/target");

        const link = editor.querySelector(".markdown-editor__surface a");
        expect(link?.textContent).toBe("Plain");
        expect(link?.getAttribute("href")).toBe("/target");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("[Plain](/target) paragraph");
    });

    it("given visual mode with an existing link, when its hover edit action is applied, then the link target changes", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "[Plain](/old) paragraph";

        document.body.append(editor);
        await waitForInitialisation();

        showLinkActions(editor, "Plain");
        clickLinkAction(editor, "Edit link");

        expect(linkTargetInput(editor).value).toBe("/old");

        applyLinkTarget(editor, "/new");

        const link = editor.querySelector(".markdown-editor__surface a");
        expect(link?.textContent).toBe("Plain");
        expect(link?.getAttribute("href")).toBe("/new");
        expect(editor.toMarkdown()).toContain("[Plain](/new) paragraph");
    });

    it("given visual mode with existing-link actions visible, when the pointer leaves the link, then the actions stay reachable", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "[Plain](/old) paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        vi.useFakeTimers();

        showLinkActions(editor, "Plain");
        editor
            .querySelector(".markdown-editor__surface p")
            ?.dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));

        expect(linkActions(editor).hidden).toBe(false);

        vi.advanceTimersByTime(499);

        expect(linkActions(editor).hidden).toBe(false);

        linkActions(editor).dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));
        vi.advanceTimersByTime(1);

        expect(linkActions(editor).hidden).toBe(false);

        clickLinkAction(editor, "Edit link");

        expect(linkTargetInput(editor).value).toBe("/old");
    });

    it("given visual mode with existing-link actions visible, when the pointer moves elsewhere, then the actions hide after a short delay", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "[Plain](/old) paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        vi.useFakeTimers();

        showLinkActions(editor, "Plain");
        editor
            .querySelector(".markdown-editor__surface p")
            ?.dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));

        expect(linkActions(editor).hidden).toBe(false);

        vi.advanceTimersByTime(500);

        expect(linkActions(editor).hidden).toBe(true);
    });

    it("given visual mode with an existing link, when its hover remove action is applied, then the link text remains", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "[Plain](/old) paragraph";

        document.body.append(editor);
        await waitForInitialisation();

        showLinkActions(editor, "Plain");
        clickLinkAction(editor, "Remove link");

        expect(editor.querySelector(".markdown-editor__surface a")).toBeNull();
        expect(editor.querySelector(".markdown-editor__surface p")?.textContent).toBe("Plain paragraph");
        expect(editor.toMarkdown()).toBe("Plain paragraph");
    });

    it("given link target editor is open, when the user clicks elsewhere, then it closes without applying a link", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        const outside = document.createElement("button");
        outside.textContent = "Outside";
        editor.textContent = "Plain paragraph";

        document.body.append(editor, outside);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Link");
        expect(linkEditor(editor).hidden).toBe(false);
        await waitForInitialisation();

        outside.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));

        expect(linkEditor(editor).hidden).toBe(true);
        expect(editor.toMarkdown()).toBe("Plain paragraph");
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

    it("given visual mode, when thematic break is selected, then a horizontal rule is inserted", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Plain");

        clickToolbarButton(editor, "Horizontal rule");

        expect(editor.querySelector(".markdown-editor__surface hr")).toBeInstanceOf(HTMLElement);
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toContain("---");
    });

    it("given visual mode, when code block is selected, then the current block becomes fenced code", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "const value = 1;";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "const value");

        clickToolbarButton(editor, "Code Block");

        expect(editor.querySelector(".markdown-editor__surface pre code")?.textContent).toBe("const value = 1;");
        expect(editor.querySelector(".markdown-editor__preview")).toBeNull();
        expect(editor.toMarkdown()).toBe(["```", "const value = 1;", "```"].join("\n"));
    });

    it("given visual mode with a list, when tab and shift-tab are pressed, then the current list item indents and outdents", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "- parent\n- child";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "child");

        dispatchVisualKey(editor, "Tab");
        expect(editor.toMarkdown()).toContain("- parent\n  - child");

        dispatchVisualKey(editor, "Tab", true);
        expect(editor.toMarkdown()).toContain("- parent\n- child");
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

    it("given split mode, when Markdown text is selected, then strike applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Strike");

        expect(editor.toMarkdown()).toContain("~~Markdown~~ paragraph");
        expect(
            editor.querySelector(
                ".markdown-editor__split .markdown-editor__surface del, .markdown-editor__split .markdown-editor__surface s",
            )?.textContent,
        ).toBe("Markdown");
    });

    it("given split mode, when Markdown text is selected, then link target applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Link");
        applyLinkTarget(editor, "/target");

        expect(editor.toMarkdown()).toContain("[Markdown](/target) paragraph");
        const link = editor.querySelector(".markdown-editor__split .markdown-editor__surface a");
        expect(link?.textContent).toBe("Markdown");
        expect(link?.getAttribute("href")).toBe("/target");
    });

    it("given unchanged editor content, when initialised, then explicit save is disabled", async (): Promise<void> => {
        const editor = document.createElement(elementName);
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();

        expect(saveButton(editor).textContent).toBe("Save");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(true);
    });

    it("given edited content, when htmx save succeeds, then save returns to clean disabled state after minimum saving time", async (): Promise<void> => {
        const { editor, field } = await initialiseEditorForm();
        vi.useFakeTimers();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");

        expect(saveButton(editor).textContent).toBe("Save");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);

        dispatchHtmxConfigRequest(editor, field);
        dispatchHtmxRequestEvent(editor, "htmx:beforeRequest");

        expect(saveButton(editor).textContent).toBe("Auto-Saving...");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(true);

        dispatchHtmxRequestEvent(editor, "htmx:afterRequest", { successful: true });

        expect(saveButton(editor).textContent).toBe("Auto-Saving...");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(true);

        vi.advanceTimersByTime(499);

        expect(saveButton(editor).textContent).toBe("Auto-Saving...");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(true);

        vi.advanceTimersByTime(1);

        expect(saveButton(editor).textContent).toBe("Save");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(true);
        expect(saveError(editor).hidden).toBe(true);
    });

    it("given edited content, when htmx save fails with an HTTP status, then save becomes retry and shows the status", async (): Promise<void> => {
        const { editor, field } = await initialiseEditorForm();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");
        dispatchHtmxConfigRequest(editor, field);
        dispatchHtmxRequestEvent(editor, "htmx:beforeRequest");

        dispatchHtmxRequestEvent(editor, "htmx:afterRequest", { successful: false, xhr: { status: 500 } });

        expect(saveButton(editor).textContent).toBe("Retry");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);
        expect(saveError(editor).hidden).toBe(false);
        expect(saveError(editor).textContent).toBe("Save failed: HTTP 500");
    });

    it("given edited content, when htmx cannot send the save request, then save shows a connection error", async (): Promise<void> => {
        const { editor, field } = await initialiseEditorForm();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");
        dispatchHtmxConfigRequest(editor, field);
        dispatchHtmxRequestEvent(editor, "htmx:beforeRequest");

        dispatchHtmxRequestEvent(editor, "htmx:sendError");

        expect(saveButton(editor).textContent).toBe("Retry");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);
        expect(saveError(editor).hidden).toBe(false);
        expect(saveError(editor).textContent).toBe("Save failed: connection error");
    });

    it("given auto-save starts, when no response arrives within ten seconds, then save becomes retry and shows an error", async (): Promise<void> => {
        const { editor, field } = await initialiseEditorForm();
        vi.useFakeTimers();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");
        dispatchHtmxConfigRequest(editor, field);
        dispatchHtmxRequestEvent(editor, "htmx:beforeRequest");

        vi.advanceTimersByTime(10_000);

        expect(saveButton(editor).textContent).toBe("Retry");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);
        expect(saveError(editor).hidden).toBe(false);
        expect(saveError(editor).textContent).toBe("Save failed: request timed out");
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

    it("given split mode, when Markdown text is selected, then code block applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown paragraph");

        clickToolbarButton(editor, "Code Block");

        expect(editor.toMarkdown()).toContain(["```", "Markdown paragraph", "```"].join("\n"));
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface pre code")?.textContent).toBe(
            "Markdown paragraph",
        );
    });

    it("given split mode, when Markdown text is selected, then thematic break applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        clickToolbarButton(editor, "Horizontal rule");

        expect(editor.toMarkdown()).toContain("Visual paragraph\n\n---");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface hr")).toBeInstanceOf(
            HTMLElement,
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

    it("given source mode, when tab and shift-tab are pressed, then the current Markdown line indents and outdents", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = "Indented paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        placeSourceCursor(editor, "Indented");

        dispatchSourceKey(editor, "Tab");
        expect(editor.toMarkdown()).toBe("    Indented paragraph");

        dispatchSourceKey(editor, "Tab", true);
        expect(editor.toMarkdown()).toBe("Indented paragraph");
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
    toolbarButton(editor, label).click();
}

/** Returns a toolbar button by its visible label. */
function toolbarButton(editor: Element, label: string): HTMLElement {
    const button = Array.from(editor.querySelectorAll(".markdown-editor__toolbar .markdown-editor__button")).find(
        (candidate: Element): boolean => toolbarButtonLabel(candidate) === label,
    );

    if (!(button instanceof HTMLElement)) {
        throw new Error(`Expected toolbar button: ${label}`);
    }

    return button;
}

/** Returns the shared toolbar tooltip. */
function toolbarTooltip(editor: Element): HTMLElement {
    const tooltip = editor.querySelector(".markdown-editor__tooltip");

    if (!(tooltip instanceof HTMLElement)) {
        throw new Error("Expected toolbar tooltip.");
    }

    return tooltip;
}

/** Returns the platform-specific primary command modifier label. */
function primaryModifierLabel(): string {
    return /\bMac/.test(navigator.platform) ? "Cmd" : "Ctrl";
}

/** Applies a link target through the editor link popover form. */
function applyLinkTarget(editor: Element, target: string): void {
    const input = linkTargetInput(editor);
    const applyButton = editor.querySelector(".markdown-editor__link-apply");

    if (!(applyButton instanceof HTMLElement)) {
        throw new Error("Expected link target editor.");
    }

    input.value = target;
    input.dispatchEvent(new InputEvent("input", { bubbles: true }));
    applyButton.click();
}

/** Returns the link target input. */
function linkTargetInput(editor: Element): HTMLInputElement {
    const input = editor.querySelector(".markdown-editor__link-target");

    if (!(input instanceof HTMLInputElement)) {
        throw new Error("Expected link target input.");
    }

    return input;
}

/** Returns the link target editor. */
function linkEditor(editor: Element): HTMLElement {
    const targetEditor = editor.querySelector(".markdown-editor__link-editor");

    if (!(targetEditor instanceof HTMLElement)) {
        throw new Error("Expected link target editor.");
    }

    return targetEditor;
}

/** Returns the existing-link action popover. */
function linkActions(editor: Element): HTMLElement {
    const actions = editor.querySelector(".markdown-editor__link-actions");

    if (!(actions instanceof HTMLElement)) {
        throw new Error("Expected link actions.");
    }

    return actions;
}

/** Shows existing-link hover actions for the visual link with matching text. */
function showLinkActions(editor: Element, linkText: string): void {
    const link = Array.from(editor.querySelectorAll(".markdown-editor__surface a")).find(
        (candidate: Element): boolean => candidate.textContent === linkText,
    );

    if (!(link instanceof HTMLAnchorElement)) {
        throw new Error(`Expected visual editor link: ${linkText}`);
    }

    link.dispatchEvent(new PointerEvent("pointerover", { bubbles: true }));
}

/** Clicks an existing-link action button by its accessible label. */
function clickLinkAction(editor: Element, label: string): void {
    const action = Array.from(editor.querySelectorAll(".markdown-editor__link-actions .markdown-editor__button")).find(
        (candidate: Element): boolean => toolbarButtonLabel(candidate) === label,
    );

    if (!(action instanceof HTMLElement)) {
        throw new Error(`Expected link action: ${label}`);
    }

    action.click();
}

/** Returns the explicit save button from the editor toolbar. */
function saveButton(editor: Element): HTMLElement {
    const button = editor.querySelector(".markdown-editor__save-button");

    if (!(button instanceof HTMLElement)) {
        throw new Error("Expected save button.");
    }

    return button;
}

/** Returns the save error message element from the editor toolbar. */
function saveError(editor: Element): HTMLElement {
    const error = editor.querySelector(".markdown-editor__save-error");

    if (!(error instanceof HTMLElement)) {
        throw new Error("Expected save error element.");
    }

    return error;
}

/** Creates an editor inside the same htmx form shape used by TestApp. */
async function initialiseEditorForm(): Promise<{ editor: MarkdownEditorElement; field: HTMLInputElement }> {
    const form = document.createElement("form");
    const editor = document.createElement(elementName) as MarkdownEditorElement;
    const field = document.createElement("input");
    field.id = "markdown-field";
    field.name = "markdown";
    field.type = "hidden";
    editor.textContent = "Plain paragraph";
    form.append(editor, field);
    document.body.append(form);
    await waitForInitialisation();

    return { editor, field };
}

/** Dispatches the htmx config request event used to copy Markdown into transport parameters. */
function dispatchHtmxConfigRequest(editor: Element, field: HTMLInputElement): void {
    editor.dispatchEvent(
        new CustomEvent("htmx:configRequest", {
            bubbles: true,
            detail: {
                parameters: {},
            },
        }),
    );

    expect(field.value).toBe((editor as MarkdownEditorElement).toMarkdown());
}

/** Dispatches an htmx request lifecycle event from the editor form. */
function dispatchHtmxRequestEvent(editor: Element, name: string, detail: Record<string, unknown> = {}): void {
    const form = editor.closest("form");

    if (!(form instanceof HTMLFormElement)) {
        throw new Error("Expected editor form.");
    }

    form.dispatchEvent(new CustomEvent(name, { bubbles: true, detail }));
}

/** Returns the view mode radio group. */
function modeControl(editor: Element): HTMLElement {
    const control = editor.querySelector(".markdown-editor__mode-group");

    if (!(control instanceof HTMLElement)) {
        throw new Error("Expected toolbar mode radio group.");
    }

    return control;
}

/** Selects an editor mode through the toolbar radio group. */
function selectMode(editor: Element, mode: string): void {
    const control = modeControl(editor);
    (control as HTMLElement & { value?: string }).value = mode;
    control.setAttribute("value", mode);
    control.dispatchEvent(new Event("change", { bubbles: true }));
}

/** Returns the block style dropdown. */
function blockStyleDropdown(editor: Element): HTMLElement {
    const dropdown = editor.querySelector(".markdown-editor__style-dropdown");

    if (!(dropdown instanceof HTMLElement)) {
        throw new Error("Expected toolbar style dropdown.");
    }

    return dropdown;
}

/** Selects a block style from the toolbar style control. */
function selectBlockStyle(editor: Element, style: string): void {
    const dropdown = blockStyleDropdown(editor);
    const item = dropdown.querySelector(`wa-dropdown-item[value="${style}"]`);

    if (!(item instanceof HTMLElement)) {
        throw new Error(`Expected toolbar style dropdown item: ${style}`);
    }

    dropdown.dispatchEvent(new CustomEvent("wa-select", { bubbles: true, detail: { item } }));
}

/** Returns the stable label for a toolbar command button. */
function toolbarButtonLabel(button: Element): string {
    return button.getAttribute("aria-label") ?? button.textContent ?? "";
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

/** Dispatches a keydown event to the CodeMirror source editor. */
function dispatchSourceKey(editor: Element, key: string, shiftKey = false): void {
    const source = editor.querySelector(".markdown-editor__source .cm-content");

    if (!(source instanceof HTMLElement)) {
        throw new Error("Expected source editor content.");
    }

    source.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key, shiftKey }));
}

/** Dispatches a keydown event to the visual editor surface. */
function dispatchVisualKey(editor: Element, key: string, shiftKey = false): void {
    const surface = editor.querySelector(".markdown-editor__surface .ProseMirror");

    if (!(surface instanceof HTMLElement)) {
        throw new Error("Expected visual editor content.");
    }

    surface.dispatchEvent(new KeyboardEvent("keydown", { bubbles: true, cancelable: true, key, shiftKey }));
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
