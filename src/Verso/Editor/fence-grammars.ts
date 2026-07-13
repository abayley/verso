import apache from "highlight.js/lib/languages/apache";
import bash from "highlight.js/lib/languages/bash";
import c from "highlight.js/lib/languages/c";
import cpp from "highlight.js/lib/languages/cpp";
import csharp from "highlight.js/lib/languages/csharp";
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
import php from "highlight.js/lib/languages/php";
import plaintext from "highlight.js/lib/languages/plaintext";
import powershell from "highlight.js/lib/languages/powershell";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import sql from "highlight.js/lib/languages/sql";
import typescript from "highlight.js/lib/languages/typescript";
import vbnet from "highlight.js/lib/languages/vbnet";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { createLowlight } from "lowlight";

/**
 * The curated set of highlight.js grammars registered for fenced code blocks (RFC-0033). Kept small on
 * purpose to bound the editor bundle; an unregistered language falls back to an unhighlighted block. The
 * canonical fence keyword is the map key; {@link CODE_BLOCK_LANGUAGES} lists them for the language picker,
 * and {@link LANGUAGE_ALIASES} maps common short spellings onto a canonical key. Shared by the visual
 * editor's code-block node and the source view's fence highlighter, so both modes agree on languages.
 */
const GRAMMARS = {
    apache,
    bash,
    c,
    cpp,
    csharp,
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
    php,
    plaintext,
    powershell,
    python,
    rust,
    sql,
    typescript,
    vbnet,
    xml,
    yaml,
} as const;

/** Common fence spellings that should resolve to a registered grammar (highlight.js's own alias names). */
const LANGUAGE_ALIASES: Readonly<Record<string, keyof typeof GRAMMARS>> = {
    "c#": "csharp",
    "c++": "cpp",
    cs: "csharp",
    csv: "plaintext",
    env: "ini",
    golang: "go",
    hs: "haskell",
    htm: "xml",
    html: "xml",
    js: "javascript",
    jsonc: "json",
    jsx: "javascript",
    md: "markdown",
    output: "plaintext",
    pem: "plaintext",
    ps1: "powershell",
    py: "python",
    rs: "rust",
    sh: "bash",
    shell: "bash",
    text: "plaintext",
    toml: "ini",
    ts: "typescript",
    tsx: "typescript",
    txt: "plaintext",
    vb: "vbnet",
    xhtml: "xml",
    yml: "yaml",
};

/** The lowlight instance carrying only the curated grammars and their aliases. */
export const fenceLowlight = createLowlight(GRAMMARS);

for (const [alias, canonical] of Object.entries(LANGUAGE_ALIASES)) {
    fenceLowlight.registerAlias(canonical, alias);
}

/* The canonical language keywords offered by the code-block language picker, alphabetical. The plaintext
   grammar exists only as the alias target for text/txt/csv/pem/output fences -- the picker already has the
   "Plain text" (no language) entry, so listing plaintext too would be a confusing near-duplicate. */
export const CODE_BLOCK_LANGUAGES: readonly string[] = Object.keys(GRAMMARS)
    .filter((language): boolean => language !== "plaintext")
    .sort();
