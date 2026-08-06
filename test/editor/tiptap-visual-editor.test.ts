import { afterEach, describe, expect, it } from "vitest";
import { documentTreeContentPipeline } from "../../src/Verso/Editor/register-extensions.js";
import { TiptapVisualEditor } from "../../src/Verso/Editor/tiptap-visual-editor.js";

describe("TiptapVisualEditor protected fragments", (): void => {
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
});
