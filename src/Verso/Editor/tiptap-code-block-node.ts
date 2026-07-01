import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import go from "highlight.js/lib/languages/go";
import haskell from "highlight.js/lib/languages/haskell";
import ini from "highlight.js/lib/languages/ini";
import java from "highlight.js/lib/languages/java";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdown from "highlight.js/lib/languages/markdown";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import sql from "highlight.js/lib/languages/sql";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { createLowlight } from "lowlight";

/**
 * The curated set of highlight.js grammars registered for fenced code blocks (RFC-0033). Kept small on
 * purpose to bound the editor bundle; an unregistered language falls back to an unhighlighted block. The
 * canonical fence keyword is the map key; {@link CODE_BLOCK_LANGUAGES} lists them for the language picker,
 * and {@link LANGUAGE_ALIASES} maps common short spellings onto a canonical key.
 */
const GRAMMARS = {
    bash,
    c,
    cpp,
    css,
    diff,
    dockerfile,
    go,
    haskell,
    ini,
    java,
    javascript,
    json,
    markdown,
    python,
    rust,
    sql,
    typescript,
    xml,
    yaml,
} as const;

/** Common fence spellings that should resolve to a registered grammar (highlight.js's own alias names). */
const LANGUAGE_ALIASES: Readonly<Record<string, keyof typeof GRAMMARS>> = {
    "c++": "cpp",
    golang: "go",
    hs: "haskell",
    htm: "xml",
    html: "xml",
    js: "javascript",
    jsx: "javascript",
    md: "markdown",
    py: "python",
    rs: "rust",
    sh: "bash",
    shell: "bash",
    toml: "ini",
    ts: "typescript",
    tsx: "typescript",
    xhtml: "xml",
    yml: "yaml",
};

/** The lowlight instance carrying only the curated grammars and their aliases. */
const lowlight = createLowlight(GRAMMARS);

for (const [alias, canonical] of Object.entries(LANGUAGE_ALIASES)) {
    lowlight.registerAlias(canonical, alias);
}

/**
 * The fenced-code-block node (RFC-0033): highlight.js highlighting via lowlight over the curated grammars,
 * replacing StarterKit's plain `codeBlock`. Keeps the standard code-block schema (a `language` attribute and
 * a text body) and the `codeBlock` node name, so existing insert commands and the DOM serialiser
 * (`codeBlockFromElement`, which reads `textContent` and the `language-` class) are unaffected.
 */
export const CodeBlock = CodeBlockLowlight.configure({ lowlight });
