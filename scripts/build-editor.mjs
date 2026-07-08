const outfile = "static/editor/markdown-editor.js";
// The Mermaid diagram runtime is built as its own bundle, loaded on demand (RFC-0033, ADR-071): it is large,
// so pages without a `mermaid` fence never pay for it.
const mermaidOutfile = "static/editor/mermaid.js";
// Basecoat chrome (RFC-0035): the precompiled nova bundle and its component
// runtime are vendored as-is (no Tailwind build), plus the Geist Variable
// font Basecoat declares but does not ship.
const basecoatCssEntry = "node_modules/basecoat-css/dist/basecoat-nova.cdn.min.css";
const basecoatCssOutfile = "static/editor/basecoat.css";
const basecoatJsEntry = "node_modules/basecoat-css/dist/js/all.min.js";
const basecoatJsOutfile = "static/editor/basecoat.js";
const geistCssEntry = "node_modules/@fontsource-variable/geist/index.css";
const geistCssOutfile = "static/editor/geist.css";
const geistFilesDir = "node_modules/@fontsource-variable/geist/files";
const geistFilesOutDir = "static/editor/files";

// Build for production: Bun resolves the "development" export condition (Lit's dev build, which
// emits "Lit is in dev mode" console warnings) unless NODE_ENV is "production". Set it before the
// build so the leaner production builds are bundled and the dev-mode warnings are dropped.
process.env.NODE_ENV = "production";

const normalisedBundle = (await buildBundle("src/Verso/Editor/index.ts")).replaceAll("`  \n`", '"  \\n"');
await Bun.write(outfile, normalisedBundle);
await Bun.write(mermaidOutfile, await buildBundle("src/Verso/Editor/mermaid-entry.ts"));
await Bun.write(basecoatCssOutfile, Bun.file(basecoatCssEntry));
await Bun.write(basecoatJsOutfile, Bun.file(basecoatJsEntry));
await Bun.write(geistCssOutfile, Bun.file(geistCssEntry));

const geistCss = await Bun.file(geistCssEntry).text();

for (const match of geistCss.matchAll(/\.\/files\/([^)'" ]+\.woff2)/g)) {
    const name = match[1];
    await Bun.write(`${geistFilesOutDir}/${name}`, Bun.file(`${geistFilesDir}/${name}`));
}

console.log(`Bundled editor to ${outfile}`);
console.log(`Bundled Mermaid runtime to ${mermaidOutfile}`);
console.log(`Vendored Basecoat to ${basecoatCssOutfile} + ${basecoatJsOutfile}, Geist to ${geistCssOutfile}`);

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
