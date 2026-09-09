import { afterEach, describe, expect, it } from "vitest";
import { CodeMirrorSourceEditor } from "../src/codemirror-source-editor.js";

const noop = (): void => {};

let editor: CodeMirrorSourceEditor | null = null;

/** Mounts a source editor over the given Markdown and attaches it to the document. */
function mountSourceEditor(markdown: string): CodeMirrorSourceEditor {
    editor = new CodeMirrorSourceEditor(markdown, noop, noop);
    document.body.append(editor.element());

    return editor;
}

afterEach((): void => {
    editor?.destroy();
    editor?.element().remove();
    editor = null;
});

describe("CodeMirrorSourceEditor fence highlighting", (): void => {
    it("given a fenced code block with a registered language, when rendered, then fence tokens carry hljs classes", (): void => {
        const mounted = mountSourceEditor(["```javascript", "const x = 1;", "```", ""].join("\n"));

        const keyword = mounted.element().querySelector(".hljs-keyword");
        expect(keyword?.textContent).toBe("const");
    });

    it("given a fence language alias, when rendered, then the aliased grammar highlights the body", (): void => {
        const mounted = mountSourceEditor(["```hs", 'main = putStrLn "hi"', "```", ""].join("\n"));

        expect(mounted.element().querySelector(".hljs-string")?.textContent).toBe('"hi"');
    });

    it("given a highlighted fence token, when rendered, then the hljs mark is innermost so its palette colour wins", (): void => {
        const mounted = mountSourceEditor(["```javascript", "const x = 1;", "```", ""].join("\n"));

        const keyword = mounted.element().querySelector(".hljs-keyword");
        // The editor palette paints all code text via a highest-precedence literal rule; the hljs
        // mark must nest inside it (no deeper span), or the fence body renders as one flat colour.
        expect(keyword?.querySelector("span")).toBeNull();
    });

    it("given plain text inside a registered fence, when rendered, then a base mark resets the literal colour", (): void => {
        const mounted = mountSourceEditor(["```javascript", "const x = 1;", "```", ""].join("\n"));

        const base = mounted.element().querySelector(".markdown-editor__fence-code");
        expect(base?.textContent).toContain("x = ");
    });

    it("given an unregistered fence language, when rendered, then the body renders without hljs classes", (): void => {
        const mounted = mountSourceEditor(["```nosuchlanguage", "const x = 1;", "```", ""].join("\n"));

        expect(mounted.element().querySelector('[class*="hljs-"]')).toBeNull();
    });

    it("given an edit replacing the document, when the fence body changes, then highlighting follows the new content", (): void => {
        const mounted = mountSourceEditor(["```javascript", "const x = 1;", "```", ""].join("\n"));

        mounted.setMarkdown(["```javascript", "return 2;", "```", ""].join("\n"));

        expect(mounted.element().querySelector(".hljs-keyword")?.textContent).toBe("return");
    });
});
