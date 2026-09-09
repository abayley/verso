const assert = require("node:assert/strict");
const { execFileSync, spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const { chromium } = require("playwright");

const net = require("node:net");

// Everything this run owns is keyed on the port it takes, so two runs at once -- a manual re-run beside a
// `make check`, which is exactly what a flake invites -- get a server, a tree and an operation log each.
// Sharing them meant the second run wiped the first run's document mid-test and both then failed on a
// 90-second selector wait, with nothing in the output to say why.
const firstPort = 8125;
let port = firstPort;
let baseUrl = `http://127.0.0.1:${port}`;
let smokeRoot = "build/smoke-tree";
let opsRoot = "build/smoke-ops";
let smokeConfig = "build/smoke.conf";
let persistedDocument = `${smokeRoot}/home.md`;

/** Takes the first free port from 8125 up, and names this run's files after it. */
async function claimPort() {
  for (let candidate = firstPort; candidate < firstPort + 25; candidate += 1) {
    if (await portIsFree(candidate)) {
      port = candidate;
      baseUrl = `http://127.0.0.1:${port}`;
      const suffix = candidate === firstPort ? "" : `-${candidate}`;
      smokeRoot = `build/smoke-tree${suffix}`;
      opsRoot = `build/smoke-ops${suffix}`;
      smokeConfig = `build/smoke${suffix}.conf`;
      persistedDocument = `${smokeRoot}/home.md`;

      return;
    }
  }

  throw new Error(`no free port in ${firstPort}..${firstPort + 24} for the smoke server`);
}

/**
 * Whether nothing is listening on a port. By connecting, not by binding: BSD lets a wildcard bind
 * succeed beside a more specific 127.0.0.1 one when either socket carries SO_REUSEADDR, so a bind
 * probe reported a port that was plainly in use as free. (The server binds loopback by default now,
 * but a connect probe is right either way, and `host = 0.0.0.0` still selects the wildcard.)
 */
function portIsFree(candidate) {
  return new Promise((resolve) => {
    const probe = net.connect({ host: "127.0.0.1", port: candidate });
    const settle = (free) => {
      probe.destroy();
      resolve(free);
    };
    probe.once("connect", () => settle(false));
    probe.once("error", () => settle(true));
    probe.setTimeout(1000, () => settle(true));
  });
}

let browser;
let serverProcess;
let serverOutput = "";

main()
  .then(() => {
    console.log("editor smoke passed");
  })
  .catch((err) => {
    console.error(err && err.stack ? err.stack : err);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (browser) {
      await browser.close();
    }

    await stopServer();
    cleanPersistedDocument();
  });

async function main() {
  await claimPort();
  prepareSmokeTree();
  serverProcess = startServer();
  await waitForServer(serverProcess);

  browser = await chromium.launch();
  const page = await browser.newPage();
  // Within `make check` the first render competes with mhs builds for the machine; the
  // default 30s selector timeout proved flaky there, so give page waits more headroom.
  page.setDefaultTimeout(Number(process.env.SMOKE_TIMEOUT ?? 90000));
  const consoleErrors = [];

  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("favicon.ico")) {
      consoleErrors.push(message.text());
    }
  });

  page.on("pageerror", (err) => {
    consoleErrors.push(err.message);
  });

  await page.goto(`${baseUrl}/documents/home.md?edit`);
  // The first render is where an overloaded machine shows up (this wait has been the one intermittent
  // failure in `make check`), and a bare selector timeout says nothing about why. Report what the page
  // actually reached -- did the bundle load, did the element upgrade, did the editor render, what document
  // was it given -- along with the memory state, then fail as before.
  try {
    await page.waitForSelector(".markdown-editor__surface h1");
  } catch (err) {
    throw new Error(`${err.message}\n${await firstRenderDiagnostics(page, consoleErrors)}`);
  }

  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);
  assert.equal(await currentEditorMode(page), "visual");

  assert.equal(
    await page.locator(".markdown-editor__surface h1").innerText(),
    "Hello from MicroHttp",
  );
  assert.equal(
    await page.locator(".markdown-editor__surface p").innerText(),
    "Edit this Markdown document.",
  );

  await page.locator(".markdown-editor__surface .ProseMirror").click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.type("## Literal heading");
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__surface")
      ?.innerText.includes("## Literal heading"),
  );
  assert.equal(await page.locator(".markdown-editor__surface h2").count(), 0);
  await selectEditorMode(page, "source");
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  assert.match(await sourceMarkdownValue(page), /\\## Literal heading/);
  await fillSourceMarkdown(
    page,
    ".markdown-editor__source",
    "# Hello from MicroHttp\n\nEdit this Markdown document.",
  );
  await selectEditorMode(page, "split");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface h1");
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface .ProseMirror");

  await page.locator(".markdown-editor__surface .ProseMirror").click();
  await page.keyboard.press(process.platform === "darwin" ? "Meta+A" : "Control+A");
  await page.keyboard.press("Backspace");
  await page.waitForFunction(() => document.querySelector(".markdown-editor__surface .ProseMirror")?.innerText.trim() === "");
  await page.keyboard.type("- ");
  await page.waitForSelector(".markdown-editor__surface li");
  await page.keyboard.type("List item");
  assert.equal(await page.locator(".markdown-editor__surface li").innerText(), "List item");
  await selectEditorMode(page, "source");
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  assert.match(await sourceMarkdownValue(page), /- List item/);
  await fillSourceMarkdown(page, ".markdown-editor__source", "Indented paragraph");
  await selectTextInElement(page, ".markdown-editor__source .cm-content", "Indented");
  await page.keyboard.press("Tab");
  assert.equal(await sourceMarkdownValue(page), "    Indented paragraph");
  await page.keyboard.press("Shift+Tab");
  assert.equal(await sourceMarkdownValue(page), "Indented paragraph");

  const multilineInlineCodeMarkdown = "`\n1\n2\n`";
  await fillSourceMarkdown(page, ".markdown-editor__source", multilineInlineCodeMarkdown);
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface code");
  await selectEditorMode(page, "source");
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  assert.equal(await sourceMarkdownValue(page), multilineInlineCodeMarkdown);

  const visualNestedListMarkdown = "- parent\n- child";
  await fillSourceMarkdown(page, ".markdown-editor__source", visualNestedListMarkdown);
  await selectEditorMode(page, "split");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface li");
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface li");
  await selectTextInElement(page, ".markdown-editor__surface .ProseMirror", "child");
  await page.keyboard.press("Tab");
  await page.waitForFunction(() => document.querySelector("markdown-editor")?.toMarkdown().includes("- parent\n  - child"));
  assert.equal(await editorMarkdownValue(page), "- parent\n  - child");
  await page.keyboard.press("Shift+Tab");
  await page.waitForFunction(() => document.querySelector("markdown-editor")?.toMarkdown() === "- parent\n- child");
  assert.equal(await editorMarkdownValue(page), visualNestedListMarkdown);

  await selectEditorMode(page, "source");
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  await fillSourceMarkdown(
    page,
    ".markdown-editor__source",
    "# Hello from MicroHttp\n\nEdit this Markdown document.",
  );

  assert.match(await sourceMarkdownValue(page), /# Hello from MicroHttp/);
  assert.match(await sourceMarkdownValue(page), /Edit this Markdown document\./);
  assert.equal(await currentEditorMode(page), "source");
  await selectEditorMode(page, "split");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface h1");
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__surface h1").innerText(),
    "Hello from MicroHttp",
  );
  assert.equal(await currentEditorMode(page), "split");
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface .ProseMirror");
  assert.equal(await currentEditorMode(page), "visual");

  await page.goto(`${baseUrl}/documents/home.md?edit&mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  const quotedSpreadListMarkdown = [
    "> 1. xxx",
    "> 2. yyy",
    ">    ",
    ">    ```typescript",
    ">    export type EditorBlock = BlockquoteBlock | CodeBlock | HeadingBlock | HorizontalRuleBlock | ListBlock | ParagraphBlock;",
    ">    ```",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", quotedSpreadListMarkdown);
  await page.waitForFunction(() => (document.querySelector(".markdown-editor__error")?.hidden ?? true) === true);
  await page.getByRole("button", { name: "Save" }).click();
  await waitForSavedDocument(page, quotedSpreadListMarkdown);
  assert.equal(await formMarkdownValue(page), quotedSpreadListMarkdown);

  const listBlockquoteMarkdown = ["- > # blockquote heading 1", "  >", "  > paragraph 1"].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", listBlockquoteMarkdown);
  await selectEditorMode(page, "split");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface blockquote h1");
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface blockquote h1");
  assert.equal(await editorMarkdownValue(page), listBlockquoteMarkdown);

  await page.goto(`${baseUrl}/documents/home.md?edit&mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  const quotedOrderedListWithCodeMarkdown = [
    "> 1. item 1",
    "> 2. item 2",
    ">    ",
    ">    ```shell",
    ">    ls -al",
    ">    ps -ef",
    ">    ```",
    ">",
    "> 3. item 3",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", quotedOrderedListWithCodeMarkdown);
  await selectEditorMode(page, "split");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface blockquote ol");
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface blockquote ol");
  assert.equal(await editorMarkdownValue(page), quotedOrderedListWithCodeMarkdown);

  await page.goto(`${baseUrl}/documents/home.md?edit&mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");

  const sourceMarkdown = [
    "# Source heading",
    "",
    "Exact **source** paragraph with [link](/target).",
    "",
    "Hard break\\",
    "continued.",
    "",
    "- first",
    "- `second`",
    "",
    "> Quoted **source** text.",
    "",
    "```typescript",
    "const value = 1;",
    "```",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", sourceMarkdown);
  await page.waitForFunction(() => (document.querySelector(".markdown-editor__error")?.hidden ?? true) === true);
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  await page.getByRole("button", { name: "Save" }).click();
  await waitForSavedDocument(page, sourceMarkdown);

  assert.equal(await formMarkdownValue(page), sourceMarkdown);

  const rawResponse = await fetch(`${baseUrl}/documents/home.md?raw`);
  assert.equal((await rawResponse.text()).trim(), sourceMarkdown);

  await page.goto(`${baseUrl}/documents/home.md?edit`);
  // Another render-after-navigation wait, so it gets the same diagnostics as the first one.
  try {
    await page.waitForSelector(".markdown-editor__surface strong");
  } catch (err) {
    throw new Error(`${err.message}\n${await firstRenderDiagnostics(page, consoleErrors)}`);
  }

  assert.equal(await page.locator(".markdown-editor__surface p strong").first().innerText(), "source");
  await page.locator('.markdown-editor__surface a[href="/target"]').hover();
  await moveMouseToParagraphEdge(page);
  await page.getByRole("button", { name: "Edit link" }).click();
  assert.equal(await page.locator(".markdown-editor__link-target").inputValue(), "/target");
  await page.locator(".markdown-editor__link-target").fill("/updated-target");
  await page.getByRole("button", { name: "Apply" }).click();
  await page.waitForSelector('.markdown-editor__surface a[href="/updated-target"]');
  assert.match(await editorMarkdownValue(page), /\[link\]\(\/updated-target\)/);
  await page.locator('.markdown-editor__surface a[href="/updated-target"]').hover();
  await page.getByRole("button", { name: "Remove link" }).click();
  await page.waitForFunction(() => !document.querySelector(".markdown-editor__surface a"));
  assert.match(await editorMarkdownValue(page), /paragraph with link\./);
  assert.match(await editorMarkdownValue(page), /Hard break\\\ncontinued\./);
  assert.equal(await page.locator(".markdown-editor__surface blockquote strong").innerText(), "source");
  assert.equal(await page.locator(".markdown-editor__surface pre code").innerText(), "const value = 1;");
  assert.deepEqual(await page.locator(".markdown-editor__surface li").allInnerTexts(), [
    "first",
    "second",
  ]);

  await page.goto(`${baseUrl}/documents/home.md?edit&mode=split`);
  await page.waitForSelector(".markdown-editor__split .markdown-editor__source .cm-editor");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface strong");
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__surface p strong").first().innerText(),
    "source",
  );

  const splitMarkdown = [
    "# Split heading",
    "",
    "Split **source** paragraph.",
    "",
    "---",
    "",
    "1. first",
    "2. second",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", splitMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Split source paragraph."),
  );
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__surface strong").innerText(),
    "source",
  );
  assert.deepEqual(
    await page.locator(".markdown-editor__split .markdown-editor__surface li").allInnerTexts(),
    ["first", "second"],
  );
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface hr");

  const sourcePaneBoldMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneBoldMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Bold" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface strong");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /\*\*Source pane\*\* paragraph\./,
  );
  assert.equal(await page.locator(".markdown-editor__split .markdown-editor__surface strong").innerText(), "Source pane");

  const sourcePaneItalicMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneItalicMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Italic" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface em");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /\*Source pane\* paragraph\./,
  );
  assert.equal(await page.locator(".markdown-editor__split .markdown-editor__surface em").innerText(), "Source pane");

  const sourcePaneCodeMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneCodeMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { exact: true, name: "Code" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface code");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /`Source pane` paragraph\./,
  );
  assert.equal(await page.locator(".markdown-editor__split .markdown-editor__surface code").innerText(), "Source pane");

  const sourcePaneMultilineCodeMarkdown = "first line\nsecond line";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneMultilineCodeMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("first line"),
  );
  await selectTextRangeInElement(
    page,
    ".markdown-editor__split .markdown-editor__source .cm-content",
    "first line",
    "second line",
  );
  await page.keyboard.press(process.platform === "darwin" ? "Meta+E" : "Control+E");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface pre code");
  assert.equal(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    "```\nfirst line\nsecond line\n```",
  );

  const sourcePaneStrikeMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneStrikeMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Strike" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface del, .markdown-editor__split .markdown-editor__surface s");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /~~Source pane~~ paragraph\./,
  );
  assert.equal(
    await page
      .locator(".markdown-editor__split .markdown-editor__surface del, .markdown-editor__split .markdown-editor__surface s")
      .innerText(),
    "Source pane",
  );

  const sourcePaneLinkMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneLinkMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Link" }).click();
  await page.locator(".markdown-editor__link-target").fill("/target");
  await page.getByRole("button", { name: "Apply" }).click();
  await page.waitForSelector('.markdown-editor__split .markdown-editor__surface a[href="/target"]');
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /\[Source pane\]\(\/target\) paragraph\./,
  );
  assert.equal(await page.locator(".markdown-editor__split .markdown-editor__surface a").innerText(), "Source pane");

  const sourcePaneBulletMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneBulletMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Bullet List" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface ul li");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /- Source pane paragraph\./,
  );
  assert.equal(await page.locator(".markdown-editor__split .markdown-editor__surface ul li").innerText(), "Source pane paragraph.");

  const sourcePaneOrderedMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneOrderedMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Ordered List" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface ol li");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /1\. Source pane paragraph\./,
  );
  assert.equal(await page.locator(".markdown-editor__split .markdown-editor__surface ol li").innerText(), "Source pane paragraph.");

  const sourcePaneBlockquoteMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneBlockquoteMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Blockquote" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface blockquote");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /> Source pane paragraph\./,
  );
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__surface blockquote").innerText(),
    "Source pane paragraph.",
  );

  const sourcePaneCodeBlockMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneCodeBlockMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane paragraph.");
  await page.getByRole("button", { name: "Code Block" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface pre code");
  assert.equal(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    ["```", "Source pane paragraph.", "```"].join("\n"),
  );
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__surface pre code").innerText(),
    "Source pane paragraph.",
  );

  const sourcePaneThematicBreakMarkdown = "Source pane paragraph.";
  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", sourcePaneThematicBreakMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Source pane paragraph."),
  );
  await selectTextInElement(page, ".markdown-editor__split .markdown-editor__source .cm-content", "Source pane");
  await page.getByRole("button", { name: "Horizontal rule" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface hr");
  assert.equal(await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"), "---");

  await fillSourceMarkdown(page, ".markdown-editor__split .markdown-editor__source", splitMarkdown);
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__split .markdown-editor__surface")
      ?.innerText.includes("Split source paragraph."),
  );
  await page.locator(".markdown-editor__split .markdown-editor__surface p").first().selectText();
  await page.getByRole("button", { name: "Bold" }).click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface p strong");
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /# Split heading/,
  );
  assert.match(
    await sourceMarkdownValue(page, ".markdown-editor__split .markdown-editor__source"),
    /\*\*Split source paragraph\.\*\*/,
  );

  await page.getByRole("button", { name: "Save" }).click();
  await waitForSavedDocument(page, /\*\*Split source paragraph\.\*\*/);
  assert.match(await formMarkdownValue(page), /\*\*Split source paragraph\.\*\*/);

  const splitRaw = await fetch(`${baseUrl}/documents/home.md?raw`);
  assert.match((await splitRaw.text()).trim(), /\*\*Split source paragraph\.\*\*/);

  await page.goto(`${baseUrl}/documents/home.md?edit`);
  await page.waitForSelector(".markdown-editor__surface hr");

  await page.goto(`${baseUrl}/documents/home.md?edit&mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  const autosavedMarkdown = [
    "# Autosaved heading",
    "",
    "Autosaved source paragraph.",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", autosavedMarkdown);
  await waitForSavedDocument(page, autosavedMarkdown);

  const autosavedRaw = await fetch(`${baseUrl}/documents/home.md?raw`);
  assert.equal((await autosavedRaw.text()).trim(), autosavedMarkdown);

  await page.goto(`${baseUrl}/documents/home.md?edit`);
  await page.waitForSelector(".markdown-editor__surface h1");
  await selectBlockStyle(page, "heading-2");
  await page.waitForSelector(".markdown-editor__surface h2");
  assert.equal(await page.locator(".markdown-editor__surface h2").innerText(), "Autosaved heading");
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  // The mark step depends on a selection existing when the button is pressed, which the
  // outcome wait cannot tell you about: with the selection gone, Bold applies to nothing and
  // the wait for <strong> simply runs its 90 seconds out. That is the shape of the one
  // intermittent failure seen here, so the precondition is checked separately and the outcome
  // wait reports what the page was in when it gave up.
  await page.locator(".markdown-editor__surface p").selectText();
  const selectedBeforeBold = await page.evaluate(() => String(window.getSelection() ?? ""));
  assert.notEqual(selectedBeforeBold, "", "expected a selection before pressing Bold");

  await page.getByRole("button", { name: "Bold" }).click();

  try {
    await page.waitForSelector(".markdown-editor__surface strong");
  } catch (err) {
    throw new Error(`${err.message}\n${await markStepDiagnostics(page, consoleErrors, selectedBeforeBold)}`);
  }
  assert.equal(await page.locator(".markdown-editor__surface strong").innerText(), "Autosaved source paragraph.");
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  assert.deepEqual(consoleErrors, []);

  await assertNoScriptFallback();
  await assertInitialContentSurvivesASplitParse(page);
}

/** Progressive enhancement (RFC-0001): with JavaScript disabled the edit page is a
 * working textarea form that saves through an ordinary post and redirect. */
async function assertNoScriptFallback() {
  const context = await browser.newContext({ javaScriptEnabled: false });

  try {
    const page = await context.newPage();
    await page.goto(`${baseUrl}/documents/home.md?edit`);

    const fallbackMarkdown = "# Saved without JavaScript\n\nThe textarea fallback works.";
    await page.locator("textarea[name='markdown']").fill(fallbackMarkdown);
    await page.getByRole("button", { name: "Save" }).click();

    // The ordinary post redirects (303) back to the edit page; the document round-trips.
    await page.waitForURL(`${baseUrl}/documents/home.md?edit`);
    await waitForSavedDocument(page, fallbackMarkdown);
    assert.equal(await page.locator("textarea[name='markdown']").inputValue(), fallbackMarkdown);
  } finally {
    await context.close();
  }
}


async function fillSourceMarkdown(page, rootSelector, markdown) {
  await page.locator(`${rootSelector} .cm-content`).fill(markdown);
}

async function sourceMarkdownValue(page, rootSelector = ".markdown-editor__source") {
  return normaliseCodeMirrorText(await page.locator(`${rootSelector} .cm-content`).innerText());
}

async function editorMarkdownValue(page) {
  return page.locator("markdown-editor").evaluate((editor) => editor.toMarkdown());
}

/** The form-associated value the markdown-editor element submits (RFC-0001), via FormData. */
async function formMarkdownValue(page) {
  return page.evaluate(() => {
    const form = document.querySelector("form");

    return form ? new FormData(form).get("markdown") : null;
  });
}

async function waitForSavedDocument(page, expected) {
  const deadline = Date.now() + 5000;

  while (Date.now() < deadline) {
    const response = await fetch(`${baseUrl}/documents/home.md?raw`);
    const text = await response.text();
    const matched = expected instanceof RegExp ? expected.test(text) : text === expected;

    if (matched) {
      return;
    }

    await page.waitForTimeout(100);
  }

  throw new Error(`Timed out waiting for saved document: ${expected.toString()}`);
}

async function currentEditorMode(page) {
  return page.locator(".markdown-editor__mode-group").getAttribute("value");
}

async function selectEditorMode(page, mode) {
  await page.locator(`.markdown-editor__mode-group [data-value="${mode}"]`).click();
  await page.waitForFunction(
    (expectedMode) => document.querySelector(".markdown-editor__mode-group")?.getAttribute("value") === expectedMode,
    mode,
  );
}

async function selectBlockStyle(page, style) {
  await page.locator(".markdown-editor__style-trigger").click();
  await page.locator(`.markdown-editor__style-dropdown [role="menuitem"][data-value="${style}"]`).click();
}

async function moveMouseToParagraphEdge(page) {
  const box = await page.locator(".markdown-editor__surface p").first().boundingBox();

  if (!box) {
    throw new Error("Expected visual editor paragraph bounds.");
  }

  await page.mouse.move(box.x + 4, box.y + box.height / 2);
}

function normaliseCodeMirrorText(text) {
  return text.replaceAll("\u00a0", " ");
}

async function selectTextInElement(page, selector, text) {
  await page.locator(selector).evaluate((root, selectedText) => {
    root.focus();

    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();

    while (node) {
      const start = node.textContent.indexOf(selectedText);

      if (start >= 0) {
        const range = document.createRange();
        range.setStart(node, start);
        range.setEnd(node, start + selectedText.length);

        const selection = window.getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
        root.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
        return;
      }

      node = walker.nextNode();
    }

    throw new Error(`Could not select text: ${selectedText}`);
  }, text);
}

async function selectTextRangeInElement(page, selector, startText, endText) {
  await page.locator(selector).evaluate(
    (root, rangeText) => {
      root.focus();

      const findTextNode = (nodeRoot, text) => {
        const walker = document.createTreeWalker(nodeRoot, NodeFilter.SHOW_TEXT);
        let node = walker.nextNode();

        while (node) {
          if (node.textContent.includes(text)) {
            return node;
          }

          node = walker.nextNode();
        }

        return null;
      };

      const startNode = findTextNode(root, rangeText.startText);
      const endNode = findTextNode(root, rangeText.endText);

      if (!startNode || !endNode) {
        throw new Error(`Could not select range: ${rangeText.startText} to ${rangeText.endText}`);
      }

      const range = document.createRange();
      range.setStart(startNode, startNode.textContent.indexOf(rangeText.startText));
      range.setEnd(endNode, endNode.textContent.indexOf(rangeText.endText) + rangeText.endText.length);

      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      root.dispatchEvent(new FocusEvent("focusin", { bubbles: true }));
    },
    { endText, startText },
  );
}


function startServer() {
  const server = spawn("./build/verso", [], {
    cwd: process.cwd(),
    detached: true,
    env: { ...process.env, MICROHTTP_CONFIG: smokeConfig },
    stdio: ["ignore", "pipe", "pipe"],
  });

  server.stdout.on("data", (chunk) => {
    serverOutput += chunk.toString();
  });
  server.stderr.on("data", (chunk) => {
    serverOutput += chunk.toString();
  });

  return server;
}

function waitForServer(server) {
  return new Promise((resolve, reject) => {
    // Settle exactly once and stop the poll loop with it: a rescheduling poll timer after a
    // rejection kept the process alive forever, so a failed startup hung the make target.
    let settled = false;
    let pollTimer = null;

    const settle = (finish, value) => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timeout);
      clearTimeout(pollTimer);
      finish(value);
    };

    const timeout = setTimeout(() => {
      settle(
        reject,
        new Error(`Timed out waiting for Verso server to start.\n${serverOutput}`),
      );
    }, 30000);

    const poll = () => {
      if (settled) {
        return;
      }
      http
        .get(baseUrl, (response) => {
          response.resume();
          settle(resolve);
        })
        .on("error", () => {
          pollTimer = setTimeout(poll, 250);
        });
    };

    server.on("exit", (code) => {
      settle(
        reject,
        new Error(`Verso server exited early with code ${code}.\n${serverOutput}`),
      );
    });
    server.on("error", (err) => {
      settle(reject, err);
    });

    poll();
  });
}

function stopServer() {
  if (
    !serverProcess
    || serverProcess.killed
    || serverProcess.exitCode !== null
    || serverProcess.signalCode !== null
  ) {
    return Promise.resolve();
  }

  return new Promise((resolve) => {
    serverProcess.once("exit", () => {
      resolve();
    });

    try {
      process.kill(-serverProcess.pid, "SIGTERM");
    } catch (_err) {
      serverProcess.kill("SIGTERM");
    }
  });
}

function cleanPersistedDocument() {
  try {
    fs.unlinkSync(persistedDocument);
  } catch (err) {
    if (err.code !== "ENOENT") {
      throw err;
    }
  }
}

/** A fresh tree-mode smoke rig: scratch tree, non-versioned, on its own port. */
/**
 * The initial document must survive the parser yielding inside the element's own markup. The page loads
 * the bundle with a plain script in <head>, so `customElements.define` runs before the body is parsed and
 * the element is upgraded at its start tag -- before the server-rendered fallback textarea that carries the
 * Markdown exists. Whether that textarea is there by the time the element reads it comes down to whether
 * the parser finished the element in one go, which an overloaded machine or a response split across
 * packets decides. When it loses, the editor renders an empty document with no error: this is the
 * intermittent `make check` failure the 90-second wait on the first heading was reporting.
 *
 * Serving the element's markup in two chunks makes that timing deterministic rather than a coin toss.
 */
async function assertInitialContentSurvivesASplitParse(page) {
  const fixtureHost = await startSplitParseFixture();

  try {
    await page.goto(fixtureHost.url);
    await page.waitForSelector(".markdown-editor__surface h1", { timeout: 15000 });
    assert.equal(await page.locator(".markdown-editor__surface h1").innerText(), "Chunked heading");
    assert.equal(await page.locator(".markdown-editor__surface p").innerText(), "Body that must survive.");
  } finally {
    await fixtureHost.close();
  }
}

/** Serves one page whose <markdown-editor> start tag and fallback textarea arrive in separate chunks. */
async function startSplitParseFixture() {
  const server = http.createServer((request, response) => {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.write(
      [
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Split parse</title>",
        `<link rel="stylesheet" href="${baseUrl}/static/editor/markdown-editor.css">`,
        `<script src="${baseUrl}/static/editor/markdown-editor.js"></script>`,
        "</head><body class=\"markdown-editor-page\"><main>",
        "<markdown-editor name=\"markdown\" data-document=\"home.md\">",
      ].join(""),
    );
    // The yield the racing page only sometimes takes: hold the element open while the browser parses
    // what it has, so the element is upgraded with no children.
    setTimeout(() => {
      response.end(
        [
          "<textarea name=\"markdown\" aria-label=\"Markdown source\" class=\"markdown-editor__fallback\">",
          "# Chunked heading\n\nBody that must survive.",
          "</textarea></markdown-editor></main></body></html>",
        ].join(""),
      );
    }, 300);
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port: fixturePort } = server.address();

  return {
    url: `http://127.0.0.1:${fixturePort}/`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/**
 * What the page reached when the first render never appeared: enough to tell an overloaded machine (the
 * editor booted but rendered late) from a broken bundle (never upgraded) from the wrong document being
 * served (rendered, but not the expected content), without needing to reproduce the failure.
 */
/** What the page was in when the Bold step failed to produce a mark. */
async function markStepDiagnostics(page, consoleErrors, selectedBeforeBold) {
  const dom = await page
    .evaluate(() => {
      const surface = document.querySelector(".markdown-editor__surface");
      const bold = document.querySelector('button[aria-label="Bold"], button[data-tooltip="Bold"]');
      const selection = window.getSelection();

      return {
        selectionNow: String(selection ?? ""),
        selectionCollapsed: selection ? selection.isCollapsed : null,
        selectionRanges: selection ? selection.rangeCount : null,
        activeElement: document.activeElement ? document.activeElement.className || document.activeElement.tagName : null,
        boldDisabled: bold ? bold.disabled : null,
        boldPressed: bold ? bold.getAttribute("aria-pressed") : null,
        surfaceHtml: surface ? surface.innerHTML.slice(0, 400) : null,
      };
    })
    .catch((evaluateError) => ({ evaluateFailed: String(evaluateError).split("\n")[0] }));

  return [
    `port: ${port}`,
    `selection before Bold: ${JSON.stringify(selectedBeforeBold)}`,
    `dom: ${JSON.stringify(dom)}`,
    `console errors: ${JSON.stringify(consoleErrors)}`,
    `server: ${JSON.stringify(serverOutput.split("\n").slice(-4))}`,
    `memory: ${memorySnapshot()}`,
  ].join("\n");
}

async function firstRenderDiagnostics(page, consoleErrors) {
  const dom = await page
    .evaluate(() => {
      const host = document.querySelector("markdown-editor");
      const surface = document.querySelector(".markdown-editor__surface");

      return {
        readyState: document.readyState,
        hostPresent: Boolean(host),
        customElementDefined: Boolean(window.customElements.get("markdown-editor")),
        bundleScriptPresent: Boolean(document.querySelector('script[src*="markdown-editor.js"]')),
        surfaceCount: document.querySelectorAll(".markdown-editor__surface").length,
        proseMirrorCount: document.querySelectorAll(".ProseMirror").length,
        surfaceText: surface ? surface.innerText.slice(0, 200) : null,
        bodyChars: document.body.innerHTML.length,
      };
    })
    .catch((evaluateError) => ({ evaluateFailed: String(evaluateError).split("\n")[0] }));

  return [
    `port: ${port}`,
    `dom: ${JSON.stringify(dom)}`,
    `console errors: ${JSON.stringify(consoleErrors)}`,
    `document on disk: ${
      fs.existsSync(persistedDocument) ? JSON.stringify(fs.readFileSync(persistedDocument, "utf8").slice(0, 200)) : "<absent>"
    }`,
    `tree: ${JSON.stringify(fs.readdirSync(smokeRoot))}`,
    `server: ${JSON.stringify(serverOutput.split("\n").slice(-4))}`,
    `memory: ${memorySnapshot()}`,
  ].join("\n");
}

/** A one-line memory reading, since exhausted swap is the leading suspect for a late first render. */
function memorySnapshot() {
  try {
    const swap = execFileSync("sysctl", ["-n", "vm.swapusage"], { encoding: "utf8" }).trim();
    const free = execFileSync("vm_stat", [], { encoding: "utf8" })
      .split("\n")
      .filter((line) => /Pages (free|active|inactive)|occupied by compressor/.test(line))
      .map((line) => line.trim())
      .join(" ");

    return `${swap} | ${free}`;
  } catch {
    return "<unavailable>";
  }
}

function prepareSmokeTree() {
  fs.rmSync(smokeRoot, { force: true, recursive: true });
  fs.rmSync(opsRoot, { force: true, recursive: true });
  fs.mkdirSync(smokeRoot, { recursive: true });
  fs.mkdirSync(opsRoot, { recursive: true });
  fs.writeFileSync(`${smokeRoot}/index.md`, "# Smoke Home\n");
  fs.writeFileSync(
    smokeConfig,
    [
      `port = ${port}`,
      `document_tree_root = ${smokeRoot}`,
      "versioning_enabled = false",
      `operation_log = ${opsRoot}/operation_log`,
      `trash_root = ${opsRoot}/trash`,
      `link_index = ${opsRoot}/link_index`,
      `draft_root = ${opsRoot}/drafts`,
      `access_log = ${opsRoot}/access.log`,
      `client_error_log = ${opsRoot}/client-errors.log`,
      "static_mounts = /static/editor packages/verso/static/editor",
      "",
    ].join("\n"),
  );
}
