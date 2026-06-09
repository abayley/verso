const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const http = require("node:http");
const { chromium } = require("playwright");

const baseUrl = "http://127.0.0.1:8080";
const persistedDocument = "data/documents/home.md";

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
  cleanPersistedDocument();
  await assertPortFree();
  serverProcess = startServer();
  await waitForServer(serverProcess);

  browser = await chromium.launch();
  const page = await browser.newPage();
  const consoleErrors = [];

  page.on("console", (message) => {
    if (message.type() === "error" && !message.text().includes("favicon.ico")) {
      consoleErrors.push(message.text());
    }
  });

  page.on("pageerror", (err) => {
    consoleErrors.push(err.message);
  });

  await page.goto(`${baseUrl}/documents/home/edit`);
  await page.waitForSelector(".markdown-editor__surface h1");
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

  await page.goto(`${baseUrl}/documents/home/edit?mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  await fillSourceMarkdown(page, ".markdown-editor__source", "<script>alert(1)</script>");
  await page.waitForSelector(".markdown-editor__error:not([hidden])");
  assert.equal(
    await page.locator(".markdown-editor__error").innerText(),
    "Unsupported Markdown node for editor subset: html",
  );

  const quotedSpreadListMarkdown = [
    "> 1. xxx",
    "> 2. yyy",
    ">    ",
    ">    ```typescript",
    ">    export type EditorBlock = BlockquoteBlock | CodeBlock | HeadingBlock | HorizontalRuleBlock | ListBlock | ParagraphBlock;",
    ">    ```",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", quotedSpreadListMarkdown);
  await page.waitForFunction(() => document.querySelector(".markdown-editor__error")?.hidden === true);
  await page.getByRole("button", { name: "Save" }).click();
  await waitForSavedDocument(page, quotedSpreadListMarkdown);
  assert.equal(await page.locator("#markdown-field").inputValue(), quotedSpreadListMarkdown);

  const listBlockquoteMarkdown = ["- > # blockquote heading 1", "  >", "  > paragraph 1"].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", listBlockquoteMarkdown);
  await selectEditorMode(page, "split");
  await page.waitForSelector(".markdown-editor__split .markdown-editor__surface blockquote h1");
  await selectEditorMode(page, "visual");
  await page.waitForSelector(".markdown-editor__surface blockquote h1");
  assert.equal(await editorMarkdownValue(page), listBlockquoteMarkdown);

  await page.goto(`${baseUrl}/documents/home/edit?mode=source`);
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

  await page.goto(`${baseUrl}/documents/home/edit?mode=source`);
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
  await page.waitForFunction(() => document.querySelector(".markdown-editor__error")?.hidden === true);
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  await page.getByRole("button", { name: "Save" }).click();
  await waitForSavedDocument(page, sourceMarkdown);

  assert.equal(await page.locator("#markdown-field").inputValue(), sourceMarkdown);

  await page.goto(`${baseUrl}/documents/home`);
  assert.equal((await page.locator("body").innerText()).trim(), sourceMarkdown);

  await page.goto(`${baseUrl}/documents/home/edit`);
  await page.waitForSelector(".markdown-editor__surface strong");
  assert.equal(await page.locator(".markdown-editor__surface p strong").first().innerText(), "source");
  assert.equal(await page.locator(".markdown-editor__surface p br").count(), 1);
  assert.equal(await page.locator(".markdown-editor__surface blockquote strong").innerText(), "source");
  assert.equal(await page.locator(".markdown-editor__surface pre code").innerText(), "const value = 1;");
  assert.deepEqual(await page.locator(".markdown-editor__surface li").allInnerTexts(), [
    "first",
    "second",
  ]);

  await page.goto(`${baseUrl}/documents/home/edit?mode=split`);
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
  assert.match(await page.locator("#markdown-field").inputValue(), /\*\*Split source paragraph\.\*\*/);

  await page.goto(`${baseUrl}/documents/home`);
  assert.match((await page.locator("body").innerText()).trim(), /\*\*Split source paragraph\.\*\*/);

  await page.goto(`${baseUrl}/documents/home/edit`);
  await page.waitForSelector(".markdown-editor__surface hr");

  await page.goto(`${baseUrl}/documents/home/edit?mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  const autosavedMarkdown = [
    "# Autosaved heading",
    "",
    "Autosaved **source** paragraph.",
  ].join("\n");
  await fillSourceMarkdown(page, ".markdown-editor__source", autosavedMarkdown);
  await waitForSavedDocument(page, autosavedMarkdown);

  await page.goto(`${baseUrl}/documents/home`);
  assert.equal((await page.locator("body").innerText()).trim(), autosavedMarkdown);

  await page.goto(`${baseUrl}/documents/home/edit`);
  await page.waitForSelector(".markdown-editor__surface h1");
  await selectBlockStyle(page, "heading-2");
  await page.waitForSelector(".markdown-editor__surface h2");
  assert.equal(await page.locator(".markdown-editor__surface h2").innerText(), "Autosaved heading");
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  await page.locator(".markdown-editor__surface p").selectText();
  await page.getByRole("button", { name: "Bold" }).click();
  await page.waitForSelector(".markdown-editor__surface strong");
  assert.equal(await page.locator(".markdown-editor__surface strong").innerText(), "Autosaved source paragraph.");
  assert.equal(await page.locator(".markdown-editor__preview").count(), 0);

  assert.deepEqual(consoleErrors, []);
}

async function assertPortFree() {
  if (await portIsOpen()) {
    throw new Error(`${baseUrl} is already in use; stop the existing TestApp server before running smoke tests.`);
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

async function waitForSavedDocument(page, expected) {
  const deadline = Date.now() + 5000;

  while (Date.now() < deadline) {
    const response = await fetch(`${baseUrl}/documents/home`, {
      headers: {
        Accept: "text/markdown",
      },
    });
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
  await page.locator(`.markdown-editor__mode-option[value="${mode}"]`).click();
  await page.waitForFunction(
    (expectedMode) => document.querySelector(".markdown-editor__mode-group")?.getAttribute("value") === expectedMode,
    mode,
  );
}

async function selectBlockStyle(page, style) {
  await page.locator(".markdown-editor__style-trigger").click();
  await page.locator(`.markdown-editor__style-dropdown wa-dropdown-item[value="${style}"]`).click();
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

function portIsOpen() {
  return new Promise((resolve) => {
    const request = http.get(baseUrl, (response) => {
      response.resume();
      resolve(true);
    });

    request.on("error", () => {
      resolve(false);
    });

    request.setTimeout(1000, () => {
      request.destroy();
      resolve(false);
    });
  });
}

function startServer() {
  const server = spawn("make", ["run-test-app"], {
    cwd: process.cwd(),
    detached: true,
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
    const timeout = setTimeout(() => {
      reject(
        new Error(
          `Timed out waiting for TestApp server to start.\n${serverOutput}`,
        ),
      );
    }, 30000);

    const poll = () => {
      http
        .get(baseUrl, (response) => {
          response.resume();
          clearTimeout(timeout);
          resolve();
        })
        .on("error", () => {
          setTimeout(poll, 250);
        });
    };

    server.on("exit", (code) => {
      clearTimeout(timeout);
      reject(
        new Error(
          `TestApp server exited early with code ${code}.\n${serverOutput}`,
        ),
      );
    });
    server.on("error", (err) => {
      clearTimeout(timeout);
      reject(err);
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
