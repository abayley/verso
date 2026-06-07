const outfile = "static/editor/markdown-editor.js";

const result = await Bun.build({
    entrypoints: ["src/TestApp/Editor/index.ts"],
    format: "iife",
    minify: true,
    outfile,
    target: "browser",
});

if (!result.success) {
    for (const log of result.logs) {
        console.error(log);
    }

    process.exit(1);
}

const bundle = await Bun.file(outfile).text();
const normalisedBundle = bundle.replaceAll("`  \n`", '"  \\n"');

await Bun.write(outfile, normalisedBundle);

console.log(`Bundled editor to ${outfile}`);
