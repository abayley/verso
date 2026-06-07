const outfile = "static/editor/markdown-editor.js";

const result = await Bun.build({
    entrypoints: ["src/TestApp/Editor/index.ts"],
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
    console.error("Editor bundle build did not produce an output file.");
    process.exit(1);
}

const bundle = await output.text();
const normalisedBundle = bundle.replaceAll("`  \n`", '"  \\n"');

await Bun.write(outfile, normalisedBundle);

console.log(`Bundled editor to ${outfile}`);
