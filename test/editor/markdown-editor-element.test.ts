import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { MarkdownEditorElement } from "../../src/TestApp/Editor/markdown-editor-element.js";

const elementName = "markdown-editor-test";

if (!customElements.get(elementName)) {
    customElements.define(elementName, MarkdownEditorElement);
}

describe("MarkdownEditorElement", (): void => {
    beforeEach((): void => {
        document.body.textContent = "";
        // The error boundary reports client errors via sendBeacon; stub it so reports never hit the
        // network (happy-dom has no sendBeacon, so the reporter would otherwise fall back to a real fetch).
        Object.defineProperty(navigator, "sendBeacon", {
            configurable: true,
            value: (): boolean => true,
            writable: true,
        });
    });

    afterEach((): void => {
        vi.useRealTimers();
        vi.restoreAllMocks();
    });

    it("given raw HTML in source mode, when initialised, then it keeps the source without a client validation error", async (): Promise<void> => {
        const editor = document.createElement(elementName);
        editor.setAttribute("mode", "source");
        editor.textContent = "<script>alert(1)</script>";

        document.body.append(editor);
        await waitForInitialisation();

        // The client no longer validates the editor subset (ADR-051); raw HTML is kept verbatim, and the
        // server stays the trust boundary that rejects it on save (ADR-041).
        expect(editor.querySelector(".markdown-editor__source .cm-editor")).toBeInstanceOf(HTMLElement);
        expect((editor as MarkdownEditorElement).toMarkdown()).toBe("<script>alert(1)</script>");
        expect(editor.querySelector(".markdown-editor__error")).toBeNull();
    });

    it("given an uncaught error on the page, when it fires, then a dismissible error banner appears", async (): Promise<void> => {
        const consoleError = vi.spyOn(console, "error").mockImplementation((): void => {});
        const editor = document.createElement(elementName);
        editor.textContent = "# Heading";

        document.body.append(editor);
        await waitForInitialisation();

        const banner = editor.querySelector(".markdown-editor__error-banner") as HTMLElement | null;
        expect(banner?.hidden).toBe(true);

        window.dispatchEvent(new ErrorEvent("error", { error: new Error("boom"), message: "boom" }));
        expect(banner?.hidden).toBe(false);

        (editor.querySelector(".markdown-editor__error-banner-dismiss") as HTMLElement).click();
        expect(banner?.hidden).toBe(true);

        consoleError.mockRestore();
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

    it("given a document with frontmatter, when loaded, then the frontmatter is hidden from the editor but re-attached to the persisted document", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = "---\nname: Test\ncover-image: assets/x.png\n---\n\n# Heading\n\nBody.";

        document.body.append(editor);
        await waitForInitialisation();

        // The editor only sees the body; the frontmatter is neither shown nor editable.
        expect(editor.toMarkdown()).toBe("# Heading\n\nBody.");
        expect(editor.toMarkdown()).not.toContain("cover-image");

        // The persisted document re-attaches the frontmatter verbatim.
        expect(editor.documentMarkdown()).toBe("---\nname: Test\ncover-image: assets/x.png\n---\n\n# Heading\n\nBody.");
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

        expect(editor.toMarkdown()).toContain("export type EditorBlock");
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

    it("given a standalone image, when loaded in the visual editor, then it is wrapped in a paragraph (a valid document)", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "![cat](/cat.png)\n\nhello world";

        document.body.append(editor);
        await waitForInitialisation();

        const surface = editor.querySelector(".markdown-editor__surface .ProseMirror");

        // A bare top-level <img> would make the document schema-invalid (the doc allows only blocks), and a
        // later insert would throw "Called contentMatchAt on a node with invalid content".
        const hasBareImageChild = Array.from(surface?.children ?? []).some(
            (child: Element): boolean => child.tagName === "IMG",
        );

        expect(hasBareImageChild).toBe(false);
        // The image renders inside its resize node-view wrapper within the paragraph.
        expect(surface?.querySelector("p img")).toBeInstanceOf(HTMLElement);
        expect(editor.toMarkdown()).toContain("![cat](/cat.png)");
    });

    it("given a callout followed by a bare image, when loaded in the visual editor, then it renders without a schema error", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        // The bare image makes the freshly-loaded document schema-invalid; the callout upgrade then
        // dispatches a transaction over that invalid document and throws "Called contentMatchAt on a node
        // with invalid content", so the visual surface never mounts. Bare images must be wrapped first.
        editor.textContent = "> [!WARNING]\n\n![cat](/cat.png)";

        document.body.append(editor);
        await waitForInitialisation();

        const surface = editor.querySelector(".markdown-editor__surface .ProseMirror");

        expect(surface).toBeInstanceOf(HTMLElement);
        expect(surface?.querySelector(".markdown-alert, [data-kind]")).toBeInstanceOf(HTMLElement);
        expect(surface?.querySelector("p img")).toBeInstanceOf(HTMLElement);
    });

    it("given a list item with a fenced code block containing blank lines, when loaded, then the fence stays one code block", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = [
            "1. First item",
            "",
            "    ```sh",
            "    SVOS> boot",
            "",
            "    Boot Profiles:",
            "",
            "    0. Console",
            "    more output",
            "    ```",
        ].join("\n");

        document.body.append(editor);
        await waitForInitialisation();

        // @tiptap/markdown alone truncates this fence at the first blank line; pre-extraction keeps it whole.
        const surface = editor.querySelector(".markdown-editor__surface");
        const codeBlocks = surface?.querySelectorAll("pre") ?? [];
        expect(codeBlocks.length).toBe(1);
        const code = codeBlocks[0]?.textContent ?? "";
        expect(code).toContain("SVOS> boot");
        expect(code).toContain("Boot Profiles:");
        expect(code).toContain("0. Console");
        expect(code).toContain("more output");

        // The fence content round-trips rather than escaping into list items.
        const out = editor.toMarkdown();
        expect(out).toContain("```sh");
        expect(out).toContain("0. Console");
        expect(out).toContain("more output");
    });

    it("given a list item with several fenced code blocks, when loaded, then each is restored", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = [
            "1. step:",
            "",
            "    ```sh",
            "    first",
            "    ```",
            "",
            "    then:",
            "",
            "    ```sh",
            "    second",
            "    ```",
            "",
            "    finally:",
            "",
            "    ```sh",
            "    third",
            "    ```",
        ].join("\n");

        document.body.append(editor);
        await waitForInitialisation();

        // Continuation sentinels in a loose list item come back indented; all three fences must still restore.
        const codeBlocks = [...(editor.querySelectorAll(".markdown-editor__surface pre") ?? [])];
        expect(codeBlocks.length).toBe(3);
        expect(codeBlocks.map((p) => (p.textContent ?? "").trim())).toEqual(["first", "second", "third"]);
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

    it("given source mode with multiline inline code, when cycled through visual, then inline code newlines are preserved", async (): Promise<void> => {
        const markdown = ["`", "1", "2", "`"].join("\n");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = markdown;

        document.body.append(editor);
        await waitForInitialisation();

        selectMode(editor, "visual");
        expect(modeControl(editor).getAttribute("value")).toBe("visual");
        selectMode(editor, "source");
        expect(modeControl(editor).getAttribute("value")).toBe("source");

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

    it("given visual mode, when a level-4 heading style is selected, then the block becomes an h4", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();

        selectBlockStyle(editor, "heading-4");

        expect(editor.querySelector(".markdown-editor__surface h4")?.textContent).toBe("Plain paragraph");
        expect(editor.toMarkdown().trim()).toBe("#### Plain paragraph");
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

    it("given visual mode, when multiline text is selected and code is pressed, then a fenced code block is inserted", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "First paragraph\n\nSecond paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectTextRange(editor, "First paragraph", "Second paragraph");

        dispatchVisualKey(editor, "e", { primaryModifier: true });

        expect(editor.toMarkdown()).toBe(["```", "First paragraph", "", "Second paragraph", "```"].join("\n"));
        expect(editor.querySelector(".markdown-editor__surface pre code")?.textContent).toBe(
            "First paragraph\n\nSecond paragraph",
        );
    });

    it("given a paragraph with a soft line break, when rendered in visual mode, then the lines join with a space", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "line one\nline two";

        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__surface p")?.textContent).toBe("line one line two");
    });

    it("given a code block with newlines, when rendered in visual mode, then the code lines are preserved", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = ["```", "first line", "second line", "```"].join("\n");

        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__surface pre code")?.textContent).toBe("first line\nsecond line");
    });

    it("given visual mode, when the selection ends at the start of a paragraph and code is pressed, then that paragraph stays outside the fence", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.textContent = "First paragraph\n\nSecond paragraph\n\nThird paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectTextRangeToBlockStart(editor, "First paragraph", "Third paragraph");

        dispatchVisualKey(editor, "e", { primaryModifier: true });

        expect(editor.toMarkdown()).toBe(
            ["```", "First paragraph", "", "Second paragraph", "```", "", "Third paragraph"].join("\n"),
        );
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

    it("given split mode, when the visual link shortcut is pressed, then link target applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Split paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectText(editor, "Split");

        dispatchVisualKey(editor, "k", { primaryModifier: true });
        applyLinkTarget(editor, "/target");

        expect(editor.toMarkdown()).toContain("[Split](/target) paragraph");
        const link = editor.querySelector(".markdown-editor__split .markdown-editor__surface a");
        expect(link?.textContent).toBe("Split");
        expect(link?.getAttribute("href")).toBe("/target");
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

    it("given split mode, when the source bold shortcut is pressed, then bold applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        dispatchSourceKey(editor, "b", { primaryModifier: true });

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

    it("given split mode, when the source italic shortcut is pressed, then italic applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        dispatchSourceKey(editor, "i", { primaryModifier: true });

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

    it("given split mode, when the source code shortcut is pressed, then code applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        dispatchSourceKey(editor, "e", { primaryModifier: true });

        expect(editor.toMarkdown()).toContain("`Markdown` paragraph");
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface code")?.textContent).toBe(
            "Markdown",
        );
    });

    it("given split mode, when multiline Markdown text is selected and source code is pressed, then a fenced code block is inserted", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nfirst line\nsecond line";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceRange(editor, "first line", "second line");

        dispatchSourceKey(editor, "e", { primaryModifier: true });

        expect(editor.toMarkdown()).toContain(["```", "first line", "second line", "```"].join("\n"));
        expect(editor.querySelector(".markdown-editor__split .markdown-editor__surface pre code")?.textContent).toBe(
            "first line\nsecond line",
        );
    });

    it("given split mode, when the source selection ends at the start of a line and code is pressed, then that line stays outside the fence", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nfirst line\nsecond line\nthird line";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceRangeToLineStart(editor, "first line", "third line");

        dispatchSourceKey(editor, "e", { primaryModifier: true });

        expect(editor.toMarkdown()).toContain(["```", "first line", "second line", "```", "third line"].join("\n"));
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

    it("given split mode, when the source strike shortcut is pressed, then strike applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        dispatchSourceKey(editor, "s", { primaryModifier: true, shiftKey: true });

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

    it("given split mode, when the source link shortcut is pressed, then link target applies to the Markdown source", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Visual paragraph\n\nMarkdown paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        selectSourceText(editor, "Markdown");

        dispatchSourceKey(editor, "k", { primaryModifier: true });
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
        const { editor } = await initialiseEditorForm();
        vi.useFakeTimers();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");

        expect(saveButton(editor).textContent).toBe("Save");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);

        dispatchHtmxConfigRequest(editor);
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
        const { editor } = await initialiseEditorForm();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");
        dispatchHtmxConfigRequest(editor);
        dispatchHtmxRequestEvent(editor, "htmx:beforeRequest");

        dispatchHtmxRequestEvent(editor, "htmx:afterRequest", { successful: false, xhr: { status: 500 } });

        expect(saveButton(editor).textContent).toBe("Retry");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);
        expect(saveError(editor).hidden).toBe(false);
        expect(saveError(editor).textContent).toBe("Save failed: HTTP 500");
    });

    it("given edited content, when htmx cannot send the save request, then save shows a connection error", async (): Promise<void> => {
        const { editor } = await initialiseEditorForm();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");
        dispatchHtmxConfigRequest(editor);
        dispatchHtmxRequestEvent(editor, "htmx:beforeRequest");

        dispatchHtmxRequestEvent(editor, "htmx:sendError");

        expect(saveButton(editor).textContent).toBe("Retry");
        expect(saveButton(editor).hasAttribute("disabled")).toBe(false);
        expect(saveError(editor).hidden).toBe(false);
        expect(saveError(editor).textContent).toBe("Save failed: connection error");
    });

    it("given auto-save starts, when no response arrives within ten seconds, then save becomes retry and shows an error", async (): Promise<void> => {
        const { editor } = await initialiseEditorForm();
        vi.useFakeTimers();

        selectText(editor, "Plain");
        clickToolbarButton(editor, "Bold");
        dispatchHtmxConfigRequest(editor);
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

    it("given source mode, when a level-5 heading style is selected, then the line gets five hashes", async (): Promise<void> => {
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = "Plain paragraph";

        document.body.append(editor);
        await waitForInitialisation();
        placeSourceCursor(editor, "Plain");

        selectBlockStyle(editor, "heading-5");

        expect(editor.toMarkdown()).toBe("##### Plain paragraph");
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
});

describe("MarkdownEditorElement visual themes", (): void => {
    const resetThemeState = (): void => {
        document.body.textContent = "";
        installLocalStorageStub();
        const root = document.documentElement;
        root.removeAttribute("data-editor-theme");
        root.classList.remove("wa-light", "wa-dark");
    };

    beforeEach(resetThemeState);
    afterEach(resetThemeState);

    it("given a theme chosen from the dropdown, when selected, then the root attribute is set and the choice persists", async (): Promise<void> => {
        const editor = document.createElement(elementName);
        document.body.append(editor);
        await waitForInitialisation();

        selectVisualTheme(editor, "aurora");

        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("aurora");
        expect(window.localStorage.getItem("editor-theme")).toBe("aurora");
    });

    it("given a stored theme, when the editor initialises, then that theme is applied", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "blueprint");

        const editor = document.createElement(elementName);
        document.body.append(editor);
        await waitForInitialisation();

        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("blueprint");
    });

    it("given an invalid stored theme, when the editor initialises, then it falls back to paper", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "not-a-theme");

        const editor = document.createElement(elementName);
        document.body.append(editor);
        await waitForInitialisation();

        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("paper");
    });

    it("given a stored colour scheme, when the editor initialises, then the scheme applies without changing the theme", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "aurora");
        window.localStorage.setItem("editor-color-scheme", "dark");

        const editor = document.createElement(elementName);
        document.body.append(editor);
        await waitForInitialisation();

        expect(document.documentElement.classList.contains("wa-dark")).toBe(true);
        expect(document.documentElement.getAttribute("data-editor-theme")).toBe("aurora");
    });

    it("given the workbench theme and no requested mode, when initialised, then it opens in split", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "workbench");

        const editor = document.createElement(elementName);
        editor.textContent = "# Heading";
        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__split")).toBeInstanceOf(HTMLElement);
    });

    it("given the workbench theme and an explicit mode, when initialised, then the explicit mode wins", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "workbench");

        const editor = document.createElement(elementName);
        editor.setAttribute("mode", "visual");
        editor.textContent = "# Heading";
        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__split")).toBeNull();
        expect(editor.querySelector(".markdown-editor__surface")).toBeInstanceOf(HTMLElement);
    });
});

describe("MarkdownEditorElement studio surfaces", (): void => {
    const resetThemeState = (): void => {
        document.body.textContent = "";
        installLocalStorageStub();
        const root = document.documentElement;
        root.removeAttribute("data-editor-theme");
        root.classList.remove("wa-light", "wa-dark");
    };

    beforeEach(resetThemeState);
    afterEach(resetThemeState);

    it("given the studio theme in visual mode, when initialised, then the command bar is suppressed", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("Edit this Markdown document.");

        expect(editor.classList.contains("markdown-editor--studio-surfaces")).toBe(true);
    });

    it("given the studio theme in source mode, when initialised, then the command bar is kept", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "source");
        editor.textContent = "Edit this Markdown document.";
        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.classList.contains("markdown-editor--studio-surfaces")).toBe(false);
    });

    it("given the studio theme in split mode, when initialised, then the command bar is kept", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        editor.setAttribute("mode", "split");
        editor.textContent = "Edit this Markdown document.";
        document.body.append(editor);
        await waitForInitialisation();

        expect(editor.classList.contains("markdown-editor--studio-surfaces")).toBe(false);
    });

    it("given the studio theme in visual mode, when switched to source, then the command bar is restored", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("Edit this Markdown document.");
        expect(editor.classList.contains("markdown-editor--studio-surfaces")).toBe(true);

        selectMode(editor, "source");

        expect(editor.classList.contains("markdown-editor--studio-surfaces")).toBe(false);
    });

    it("given the studio theme and a non-empty visual selection, when the selection changes, then the bubble toolbar shows", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("Edit this Markdown document.");

        selectText(editor, "Markdown");
        dispatchSelectionChange();

        expect(bubbleToolbar(editor).hidden).toBe(false);
    });

    it("given the studio bubble toolbar, when Bold is clicked, then bold applies to the Markdown", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("Edit this Markdown document.");

        selectText(editor, "Markdown");
        dispatchSelectionChange();
        bubbleButton(editor, "strong").dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(editor.toMarkdown()).toContain("**Markdown**");
    });

    it("given a heading selected in studio, when Paragraph is chosen from the bubble, then the block becomes a paragraph", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("# A heading");

        selectText(editor, "A heading");
        dispatchSelectionChange();
        selectBubbleStyle(editor, "paragraph");

        expect(editor.querySelector(".markdown-editor__surface h1")).toBeNull();
        expect(editor.toMarkdown()).toContain("A heading");
        expect(editor.toMarkdown()).not.toContain("# A heading");
    });

    it("given a paragraph selected in studio, when Heading 1 is chosen from the bubble, then the block becomes a heading", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("Just a paragraph");

        selectText(editor, "Just a paragraph");
        dispatchSelectionChange();
        selectBubbleStyle(editor, "heading-1");

        expect(editor.querySelector(".markdown-editor__surface h1")).toBeInstanceOf(HTMLElement);
        expect(editor.toMarkdown()).toContain("# Just a paragraph");
    });

    it("given a heading selected in studio, when the bubble shows, then its block selector reflects the heading", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("# A heading");

        selectText(editor, "A heading");
        dispatchSelectionChange();

        expect(bubbleToolbar(editor).querySelector(".markdown-editor__bubble-style-trigger")?.textContent).toBe(
            "Heading 1",
        );
    });

    it("given the studio bubble toolbar shown, when the selection collapses, then the bubble toolbar hides", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("Edit this Markdown document.");

        selectText(editor, "Markdown");
        dispatchSelectionChange();
        expect(bubbleToolbar(editor).hidden).toBe(false);

        window.getSelection()?.removeAllRanges();
        dispatchSelectionChange();

        expect(bubbleToolbar(editor).hidden).toBe(true);
    });

    it("given the paper theme and a non-empty visual selection, when the selection changes, then the bubble toolbar stays hidden", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "paper");
        const editor = await mountStudioEditor("Edit this Markdown document.");

        selectText(editor, "Markdown");
        dispatchSelectionChange();

        expect(bubbleToolbar(editor).hidden).toBe(true);
    });

    it("given the studio theme and a block typed as a slash, when the selection changes, then the slash menu opens", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("/");

        placeCaretAfterText(editor, "/");
        dispatchSelectionChange();

        expect(slashMenu(editor).hidden).toBe(false);
        expect(slashMenu(editor).querySelectorAll(".markdown-editor__slash-item").length).toBe(15);
    });

    it("given the studio slash menu, when Heading 1 is chosen, then the block becomes a heading", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("/");

        placeCaretAfterText(editor, "/");
        dispatchSelectionChange();
        slashItem(editor, "Heading 1").dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(editor.querySelector(".markdown-editor__surface h1")).toBeInstanceOf(HTMLElement);
        expect(slashMenu(editor).hidden).toBe(true);
    });

    it("given the studio slash menu, when Bullet list is chosen, then the block becomes a list", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("/");

        placeCaretAfterText(editor, "/");
        dispatchSelectionChange();
        slashItem(editor, "Bullet list").dispatchEvent(new MouseEvent("click", { bubbles: true }));

        expect(editor.querySelector(".markdown-editor__surface ul li")).toBeInstanceOf(HTMLElement);
    });

    it("given the studio slash menu open, when Escape is pressed, then it closes", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "studio");
        const editor = await mountStudioEditor("/");

        placeCaretAfterText(editor, "/");
        dispatchSelectionChange();
        expect(slashMenu(editor).hidden).toBe(false);

        editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));

        expect(slashMenu(editor).hidden).toBe(true);
    });

    it("given the paper theme and a block typed as a slash, when the selection changes, then the slash menu stays hidden", async (): Promise<void> => {
        window.localStorage.setItem("editor-theme", "paper");
        const editor = await mountStudioEditor("/");

        placeCaretAfterText(editor, "/");
        dispatchSelectionChange();

        expect(slashMenu(editor).hidden).toBe(true);
    });
});

describe("MarkdownEditorElement form participation", (): void => {
    afterEach((): void => {
        document.body.textContent = "";
    });

    it("given an element wrapping a textarea, when initialised, then it adopts the content and disables the textarea", async (): Promise<void> => {
        const form = document.createElement("form");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        const textarea = document.createElement("textarea");
        textarea.name = "markdown";
        textarea.value = "# Adopted\n\nFrom the textarea.";
        editor.append(textarea);
        form.append(editor);
        document.body.append(form);
        await waitForInitialisation();

        expect(editor.toMarkdown()).toContain("# Adopted");
        expect(editor.toMarkdown()).toContain("From the textarea.");
        expect(textarea.disabled).toBe(true);
        expect(editor.contains(textarea)).toBe(true);
    });

    it("given a wrapped textarea, when initialised, then the rich editor renders and the textarea is hidden", async (): Promise<void> => {
        const form = document.createElement("form");
        const editor = document.createElement(elementName) as MarkdownEditorElement;
        const textarea = document.createElement("textarea");
        textarea.name = "markdown";
        textarea.value = "Plain paragraph";
        editor.append(textarea);
        form.append(editor);
        document.body.append(form);
        await waitForInitialisation();

        expect(editor.querySelector(".markdown-editor__surface .ProseMirror")).toBeInstanceOf(HTMLElement);
        expect(textarea.hidden).toBe(true);
    });
});

/** Mounts a visual-mode editor with the given Markdown and waits for it to initialise. */
async function mountStudioEditor(markdown: string): Promise<MarkdownEditorElement> {
    const editor = document.createElement(elementName) as MarkdownEditorElement;
    editor.textContent = markdown;
    document.body.append(editor);
    await waitForInitialisation();

    return editor;
}

/** Dispatches a document selectionchange event, which happy-dom does not emit on programmatic selection. */
function dispatchSelectionChange(): void {
    document.dispatchEvent(new Event("selectionchange"));
}

/** Returns the bubble toolbar element for assertions. */
function bubbleToolbar(editor: Element): HTMLElement {
    const bubble = editor.querySelector(".markdown-editor__bubble");

    if (!(bubble instanceof HTMLElement)) {
        throw new Error("Expected a bubble toolbar.");
    }

    return bubble;
}

/** Returns one bubble toolbar button by its inline style. */
function bubbleButton(editor: Element, style: string): HTMLElement {
    const button = bubbleToolbar(editor).querySelector(`.markdown-editor__bubble-button[data-inline-style="${style}"]`);

    if (!(button instanceof HTMLElement)) {
        throw new Error(`Expected a bubble button: ${style}`);
    }

    return button;
}

/** Chooses a block style from the bubble toolbar's block selector. */
function selectBubbleStyle(editor: Element, style: string): void {
    const dropdown = bubbleToolbar(editor).querySelector(".markdown-editor__bubble-style");

    if (!dropdown) {
        throw new Error("Expected a bubble block-style dropdown.");
    }

    const item = dropdown.querySelector(`wa-dropdown-item[value="${style}"]`);

    if (!item) {
        throw new Error(`Expected a bubble block-style item: ${style}`);
    }

    dropdown.dispatchEvent(new CustomEvent("wa-select", { detail: { item } }));
}

/** Returns the slash menu element for assertions. */
function slashMenu(editor: Element): HTMLElement {
    const menu = editor.querySelector(".markdown-editor__slash-menu");

    if (!(menu instanceof HTMLElement)) {
        throw new Error("Expected a slash menu.");
    }

    return menu;
}

/** Returns one slash menu item by its label. */
function slashItem(editor: Element, label: string): HTMLElement {
    const item = Array.from(slashMenu(editor).querySelectorAll(".markdown-editor__slash-item")).find(
        (candidate): boolean => candidate.textContent === label,
    );

    if (!(item instanceof HTMLElement)) {
        throw new Error(`Expected a slash item: ${label}`);
    }

    return item;
}

/** Places a collapsed caret immediately after the given rendered text. */
function placeCaretAfterText(editor: Element, text: string): void {
    const surface = editor.querySelector(".markdown-editor__surface");

    if (!(surface instanceof HTMLElement)) {
        throw new Error("Expected visual editor surface.");
    }

    const textNode = findTextNode(surface, text);

    if (!textNode) {
        throw new Error(`Expected text node containing: ${text}`);
    }

    const range = document.createRange();
    range.setStart(textNode, textNode.data.indexOf(text) + text.length);
    range.collapse(true);

    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
}

/** Installs a fresh in-memory localStorage on window, since the test runtime
 * does not provide one (the editor reads window.localStorage). */
function installLocalStorageStub(): void {
    const store = new Map<string, string>();
    const stub: Storage = {
        get length(): number {
            return store.size;
        },
        clear(): void {
            store.clear();
        },
        getItem(key: string): string | null {
            return store.has(key) ? (store.get(key) as string) : null;
        },
        key(index: number): string | null {
            return Array.from(store.keys())[index] ?? null;
        },
        removeItem(key: string): void {
            store.delete(key);
        },
        setItem(key: string, value: string): void {
            store.set(key, value);
        },
    };
    Object.defineProperty(window, "localStorage", { configurable: true, value: stub });
}

/** Selects a visual theme by dispatching the theme dropdown's selection event. */
function selectVisualTheme(editor: Element, theme: string): void {
    const dropdown = editor.querySelector(".markdown-editor__theme-dropdown");

    if (!dropdown) {
        throw new Error("Expected a theme dropdown.");
    }

    const item = dropdown.querySelector(`wa-dropdown-item[value="${theme}"]`);

    if (!item) {
        throw new Error(`Expected a theme dropdown item: ${theme}`);
    }

    dropdown.dispatchEvent(new CustomEvent("wa-select", { detail: { item } }));
}

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
async function initialiseEditorForm(): Promise<{ editor: MarkdownEditorElement }> {
    const form = document.createElement("form");
    const editor = document.createElement(elementName) as MarkdownEditorElement;
    editor.textContent = "Plain paragraph";
    form.append(editor);
    document.body.append(form);
    await waitForInitialisation();

    return { editor };
}

/** Dispatches the htmx config request event and asserts the live Markdown reaches the request parameters. */
function dispatchHtmxConfigRequest(editor: Element): void {
    const parameters: Record<string, unknown> = {};
    editor.dispatchEvent(
        new CustomEvent("htmx:configRequest", {
            bubbles: true,
            detail: {
                parameters,
            },
        }),
    );

    expect(parameters["markdown"]).toBe((editor as MarkdownEditorElement).toMarkdown());
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

/** Selects rendered visual text from one fragment to another. */
function selectTextRange(editor: Element, startText: string, endText: string): void {
    setVisualRange(editor, startText, endText, "after");
}

/** Selects rendered visual text from one fragment to the start of another block. */
function selectTextRangeToBlockStart(editor: Element, startText: string, endText: string): void {
    setVisualRange(editor, startText, endText, "before");
}

/** Selects a rendered visual range ending before or after the end text fragment. */
function setVisualRange(editor: Element, startText: string, endText: string, endEdge: "before" | "after"): void {
    const root = editor.querySelector(".markdown-editor__surface .ProseMirror") ?? editor;
    const startNode = findTextNode(root, startText);
    const endNode = findTextNode(root, endText);

    if (!startNode || !endNode) {
        throw new Error(`Expected rendered text range from ${startText} to ${endText}.`);
    }

    const range = document.createRange();
    range.setStart(startNode, startNode.data.indexOf(startText));
    range.setEnd(endNode, endNode.data.indexOf(endText) + (endEdge === "after" ? endText.length : 0));

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

/** Selects a source range from the start of one text fragment to the end of another. */
function selectSourceRange(editor: Element, startText: string, endText: string): void {
    setSourceRange(editor, startText, endText, "after");
}

/** Selects a source range from the start of one text fragment to the start of another line. */
function selectSourceRangeToLineStart(editor: Element, startText: string, endText: string): void {
    setSourceRange(editor, startText, endText, "before");
}

/** Selects a source range ending before or after the end text fragment. */
function setSourceRange(editor: Element, startText: string, endText: string, endEdge: "before" | "after"): void {
    const source = editor.querySelector(".markdown-editor__source .cm-content");

    if (!(source instanceof HTMLElement)) {
        throw new Error("Expected source editor content.");
    }

    const startNode = findTextNode(source, startText);
    const endNode = findTextNode(source, endText);

    if (!startNode || !endNode) {
        throw new Error(`Expected source range from ${startText} to ${endText}.`);
    }

    const range = document.createRange();
    range.setStart(startNode, startNode.data.indexOf(startText));
    range.setEnd(endNode, endNode.data.indexOf(endText) + (endEdge === "after" ? endText.length : 0));

    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);
    source.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
}

interface EditorKeyOptions {
    primaryModifier?: boolean;
    shiftKey?: boolean;
}

/** Dispatches a keydown event to the CodeMirror source editor. */
function dispatchSourceKey(editor: Element, key: string, options: EditorKeyOptions | boolean = {}): void {
    const source = editor.querySelector(".markdown-editor__source .cm-content");

    if (!(source instanceof HTMLElement)) {
        throw new Error("Expected source editor content.");
    }

    const keyOptions = typeof options === "boolean" ? { shiftKey: options } : options;

    source.dispatchEvent(
        new KeyboardEvent("keydown", {
            bubbles: true,
            cancelable: true,
            ctrlKey: Boolean(keyOptions.primaryModifier),
            key,
            metaKey: Boolean(keyOptions.primaryModifier),
            shiftKey: Boolean(keyOptions.shiftKey),
        }),
    );
}

/** Dispatches a keydown event to the visual editor surface. */
function dispatchVisualKey(editor: Element, key: string, options: EditorKeyOptions | boolean = {}): void {
    const surface = editor.querySelector(".markdown-editor__surface .ProseMirror");

    if (!(surface instanceof HTMLElement)) {
        throw new Error("Expected visual editor content.");
    }

    const keyOptions = typeof options === "boolean" ? { shiftKey: options } : options;

    surface.dispatchEvent(
        new KeyboardEvent("keydown", {
            bubbles: true,
            cancelable: true,
            ctrlKey: Boolean(keyOptions.primaryModifier),
            key,
            metaKey: Boolean(keyOptions.primaryModifier),
            shiftKey: Boolean(keyOptions.shiftKey),
        }),
    );
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
