import { afterEach, describe, expect, it } from "vitest";
import { documentTreeContentPipeline } from "../src/register-extensions.js";
import { TiptapVisualEditor } from "../src/tiptap-visual-editor.js";

describe("TiptapVisualEditor", (): void => {
    let editor: TiptapVisualEditor | null = null;

    afterEach((): void => {
        editor?.destroy();
        editor = null;
        document.body.replaceChildren();
    });

    it("given every protected fragment, when constructed and replaced, then the shipping pipeline round-trips them", (): void => {
        const markdown = [
            "Before `READY`{.badge.green} <kbd>Ctrl</kbd> [guide][docs] and note[^note].",
            "",
            "```markdown",
            "`INNER`{.badge.red}",
            "[^fake]: protected footnote",
            "[docs]: /protected-reference",
            "<em>protected HTML</em>",
            "```",
            "",
            "[^note]: Footnote body.",
            "",
            '[docs]: /guide "Guide"',
        ].join("\n");
        editor = new TiptapVisualEditor(
            markdown,
            (): void => {},
            (): void => {},
            documentTreeContentPipeline,
            { preserveRawHtml: true },
        );
        document.body.append(editor.element());

        expect(editor.toMarkdown()).toBe(markdown);

        editor.setMarkdown(markdown);

        expect(editor.toMarkdown()).toBe(markdown);
    });

    it("given unchanged content, when the selection moves, then the selection change handler runs", (): void => {
        let selectionChanges = 0;
        const options = {
            onSelectionChange: (): void => {
                selectionChanges += 1;
            },
            preserveRawHtml: true,
        };
        editor = new TiptapVisualEditor(
            "*italic line*\n\n`code span line`",
            (): void => {},
            (): void => {},
            documentTreeContentPipeline,
            options,
        );
        document.body.append(editor.element());

        editor.select(2, 2);

        expect(selectionChanges).toBe(1);
    });

    it("given an active stored mark on an empty text block, when toggled, then the mark is removed", (): void => {
        editor = new TiptapVisualEditor(
            "",
            (): void => {},
            (): void => {},
            documentTreeContentPipeline,
            { preserveRawHtml: true },
        );
        document.body.append(editor.element());
        editor.select(1, 1);
        const paragraph = editor.element().querySelector(".ProseMirror p");
        if (!(paragraph instanceof HTMLParagraphElement)) {
            throw new Error("Expected an empty visual paragraph.");
        }
        const range = document.createRange();
        range.setStart(paragraph, 0);
        range.collapse(true);
        window.getSelection()?.removeAllRanges();
        window.getSelection()?.addRange(range);
        editor.toggleInlineStyle("strong");
        expect(editor.isInlineActive("strong")).toBe(true);

        editor.toggleInlineStyle("strong");

        expect(editor.isInlineActive("strong")).toBe(false);
    });
});
