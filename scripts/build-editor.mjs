const outfile = "static/editor/markdown-editor.js";
const webAwesomeCssEntry = "node_modules/@awesome.me/webawesome/dist/styles/themes/default.css";
const webAwesomeCssOutfile = "static/editor/webawesome.css";

// Build for production: Bun resolves the "development" export condition (Lit's dev build, which
// emits "Lit is in dev mode" console warnings) unless NODE_ENV is "production". Set it before the
// build so the leaner production builds are bundled and the dev-mode warnings are dropped.
process.env.NODE_ENV = "production";

const result = await Bun.build({
    entrypoints: ["src/TestApp/Editor/index.ts"],
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
    console.error("Editor bundle build did not produce an output file.");
    process.exit(1);
}

const bundle = await output.text();
const normalisedBundle = bundle.replaceAll("`  \n`", '"  \\n"');

await Bun.write(outfile, normalisedBundle);
await Bun.write(webAwesomeCssOutfile, await bundledCss(webAwesomeCssEntry));

console.log(`Bundled editor to ${outfile}`);
console.log(`Bundled Web Awesome styles to ${webAwesomeCssOutfile}`);

/** Bundles a CSS file by recursively inlining relative @import URLs. */
async function bundledCss(path, seen = new Set()) {
    if (seen.has(path)) {
        return "";
    }

    seen.add(path);

    const css = await Bun.file(path).text();
    const directory = path.slice(0, path.lastIndexOf("/"));

    const importPattern = /@import\s+url\(['"]?([^'")]+)['"]?\);/g;
    let bundled = "";
    let offset = 0;

    for (const match of css.matchAll(importPattern)) {
        const importPath = match[1];
        const matchIndex = match.index ?? 0;
        bundled += css.slice(offset, matchIndex);
        offset = matchIndex + match[0].length;

        if (importPath.startsWith("http://") || importPath.startsWith("https://")) {
            bundled += `@import url('${importPath}');`;
            continue;
        }

        const normalisedPath = normalisePath(`${directory}/${importPath}`);
        const importedCss = await bundledCss(normalisedPath, seen);

        bundled += `\n/* ${normalisedPath} */\n${importedCss}`;
    }

    return bundled + css.slice(offset);
}

/** Normalises simple relative path segments in package CSS imports. */
function normalisePath(path) {
    const segments = [];

    for (const segment of path.split("/")) {
        if (segment === "." || segment === "") {
            continue;
        }

        if (segment === "..") {
            segments.pop();
            continue;
        }

        segments.push(segment);
    }

    return segments.join("/");
}
