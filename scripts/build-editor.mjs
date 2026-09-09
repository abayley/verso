import { checkEditorLayoutCss } from "../src/Verso/Editor/editor-layout.ts";
import { checkVisualThemeCss } from "../src/Verso/Editor/visual-theme-registry.ts";

const outfile = "static/editor/markdown-editor.js";
// The small classic appearance bootstrap runs synchronously before the stylesheets so stored
// browser preferences reach the root before first paint.
const appearanceBootstrapOutfile = "static/editor/appearance-bootstrap.js";
// The Mermaid diagram runtime is built as its own bundle, loaded on demand (RFC-0033, ADR-0071): it is large,
// so pages without a `mermaid` fence never pay for it.
const mermaidOutfile = "static/editor/mermaid.js";
// Basecoat chrome (RFC-0035): the precompiled nova bundle and its component
// runtime are vendored as-is (no Tailwind build).
const basecoatCssEntry = "node_modules/basecoat-css/dist/basecoat-nova.cdn.min.css";
const basecoatCssOutfile = "static/editor/basecoat.css";
const basecoatJsEntry = "node_modules/basecoat-css/dist/js/all.min.js";
const basecoatJsOutfile = "static/editor/basecoat.js";
// The page fonts, self-hosted rather than fetched from a font CDN: the server is expected to run on a
// private network, and the chrome should not depend on reaching one. Roboto for text and Roboto Mono for
// code (the stylesheet names them, with the system stacks behind them); each package's index.css carries
// per-script @font-face rules, and only the woff2 subsets it actually references are copied.
const fontPackages = [
    { name: "Roboto", package: "@fontsource-variable/roboto", outfile: "static/editor/roboto.css" },
    { name: "Roboto Mono", package: "@fontsource-variable/roboto-mono", outfile: "static/editor/roboto-mono.css" },
];
const fontFilesOutDir = "static/editor/files";
const editorStylesheet = "static/editor/markdown-editor.css";

// Build for production: Bun resolves the "development" export condition (Lit's dev build, which
// emits "Lit is in dev mode" console warnings) unless NODE_ENV is "production". Set it before the
// build so the leaner production builds are bundled and the dev-mode warnings are dropped.
process.env.NODE_ENV = "production";

const editorCss = await Bun.file(editorStylesheet).text();
const themeCssCheck = checkVisualThemeCss(editorCss);
if (themeCssCheck.missingThemeIds.length > 0 || themeCssCheck.unregisteredThemeIds.length > 0) {
    console.error(
        `Visual theme CSS does not match the registry. Missing selectors: ${themeCssCheck.missingThemeIds.join(", ") || "none"}. Unregistered selectors: ${themeCssCheck.unregisteredThemeIds.join(", ") || "none"}.`,
    );
    process.exit(1);
}

const layoutCssError = checkEditorLayoutCss(editorCss);
if (layoutCssError !== null) {
    console.error(layoutCssError);
    process.exit(1);
}

const normalisedBundle = (await buildBundle("src/Verso/Editor/index.ts")).replaceAll("`  \n`", '"  \\n"');
await Bun.write(outfile, normalisedBundle);
await Bun.write(appearanceBootstrapOutfile, await buildBundle("src/Verso/Editor/appearance-bootstrap.ts"));
await Bun.write(mermaidOutfile, await buildBundle("src/Verso/Editor/mermaid-entry.ts"));
await Bun.write(basecoatCssOutfile, Bun.file(basecoatCssEntry));
await Bun.write(basecoatJsOutfile, Bun.file(basecoatJsEntry));
for (const font of fontPackages) {
    const entry = `node_modules/${font.package}/index.css`;
    await Bun.write(font.outfile, Bun.file(entry));

    const css = await Bun.file(entry).text();

    for (const match of css.matchAll(/\.\/files\/([^)'" ]+\.woff2)/g)) {
        const name = match[1];
        await Bun.write(`${fontFilesOutDir}/${name}`, Bun.file(`node_modules/${font.package}/files/${name}`));
    }
}

console.log(`Bundled editor to ${outfile}`);
console.log(`Bundled appearance bootstrap to ${appearanceBootstrapOutfile}`);
console.log(`Bundled Mermaid runtime to ${mermaidOutfile}`);
console.log(`Vendored Basecoat to ${basecoatCssOutfile} + ${basecoatJsOutfile}`);
console.log(`Vendored fonts: ${fontPackages.map((font) => `${font.name} to ${font.outfile}`).join(", ")}`);

/** Builds one IIFE browser bundle from an entrypoint and returns its source, exiting on failure. */
async function buildBundle(entrypoint) {
    const result = await Bun.build({
        entrypoints: [entrypoint],
        define: { "process.env.NODE_ENV": '"production"' },
        format: "iife",
        minify: true,
        target: "browser",
    });

    if (!result.success) {
        for (const log of result.logs) {
            console.error(log);
        }

        process.exit(1);
    }

    const output = result.outputs[0];

    if (!output) {
        console.error(`Bundle build for ${entrypoint} produced no output file.`);
        process.exit(1);
    }

    return output.text();
}
