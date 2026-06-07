import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { mkdir, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const depsRequire = createRequire(`${process.cwd()}/build/remark-spike-deps/package.json`);

const { unified } = await importResolved("unified");
const remarkParse = (await importResolved("remark-parse")).default;
const remarkStringify = (await importResolved("remark-stringify")).default;
const remarkGfm = (await importResolved("remark-gfm")).default;
const remarkRehype = (await importResolved("remark-rehype")).default;
const rehypeStringify = (await importResolved("rehype-stringify")).default;

const markdownProcessor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkStringify, {
    bullet: "-",
    fences: true,
    listItemIndent: "one",
  });

const htmlProcessor = unified()
  .use(remarkParse)
  .use(remarkGfm)
  .use(remarkRehype)
  .use(rehypeStringify);

const acceptedMarkdown = [
  "# Heading",
  "",
  "A **strong** and *em* paragraph with `code` and [link](/target).",
  "",
  "- first",
  "- second",
  "",
  "1. one",
  "2. two",
].join("\n");

const rawHtmlMarkdown = "<script>alert(1)</script>";
const tableMarkdown = ["| Name | Value |", "| --- | --- |", "| one | two |"].join("\n");
const imageMarkdown = "![Alt text](attachments/example.png)";

const acceptedTree = markdownProcessor.parse(acceptedMarkdown);
const acceptedValidation = validateCurrentSubset(acceptedTree);
assert.deepEqual(acceptedValidation, []);

const normalisedMarkdown = String(await markdownProcessor.process(acceptedMarkdown));
const html = String(await htmlProcessor.process(acceptedMarkdown));

assert.equal(validateCurrentSubset(markdownProcessor.parse(rawHtmlMarkdown))[0].type, "html");
assert.equal(validateCurrentSubset(markdownProcessor.parse(tableMarkdown))[0].type, "table");
assert.equal(validateCurrentSubset(markdownProcessor.parse(imageMarkdown))[0].type, "image");

const report = {
  acceptedNodeTypes: Array.from(nodeTypes(acceptedTree)).sort(),
  acceptedValidation,
  deferredExamples: {
    rawHtml: validateCurrentSubset(markdownProcessor.parse(rawHtmlMarkdown)),
    table: validateCurrentSubset(markdownProcessor.parse(tableMarkdown)),
    image: validateCurrentSubset(markdownProcessor.parse(imageMarkdown)),
  },
  normalisedMarkdown,
  html,
  observations: [
    "remark produces an mdast tree that matches the editor's Markdown-shaped subset.",
    "remark-gfm recognises tables as table nodes, which can be rejected until the asset/table phase.",
    "Raw HTML is visible as html nodes, so server-side validation can reject it before rendering.",
    "The current browser/server hand parser can be replaced by an mdast validation and rendering adapter later.",
  ],
};

await mkdir("build/remark-spike", { recursive: true });
await writeFile("build/remark-spike/report.json", `${JSON.stringify(report, null, 2)}\n`);
console.log("remark AST spike passed");
console.log("report: build/remark-spike/report.json");

async function importResolved(packageName) {
  const resolved = depsRequire.resolve(packageName);
  return import(pathToFileURL(resolved).href);
}

function validateCurrentSubset(tree) {
  const errors = [];
  visit(tree, (node) => {
    if (!allowedNode(node)) {
      errors.push({
        type: node.type,
        reason: "unsupported by current markdown editor spike subset",
      });
    }
  });
  return errors;
}

function allowedNode(node) {
  return [
    "root",
    "heading",
    "paragraph",
    "text",
    "strong",
    "emphasis",
    "inlineCode",
    "link",
    "list",
    "listItem",
  ].includes(node.type);
}

function visit(node, visitor) {
  visitor(node);
  for (const child of node.children || []) {
    visit(child, visitor);
  }
}

function nodeTypes(tree) {
  const types = new Set();
  visit(tree, (node) => types.add(node.type));
  return types;
}
