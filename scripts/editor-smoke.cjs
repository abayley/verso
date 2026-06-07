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
  assert.deepEqual(await page.locator(".markdown-editor__toolbar button").allInnerTexts(), [
    "Visual",
    "Markdown",
    "Split",
  ]);
  assert.equal(
    await page.locator('.markdown-editor__toolbar button[data-mode="visual"]').getAttribute("aria-pressed"),
    "true",
  );

  assert.equal(
    await page.locator(".markdown-editor__surface h1").innerText(),
    "Hello from MicroHttp",
  );
  assert.equal(
    await page.locator(".markdown-editor__surface p").innerText(),
    "Edit this Markdown document.",
  );

  await page.getByRole("button", { name: "Save" }).click();
  await page.waitForFunction(() =>
    document
      .querySelector("#save-status")
      ?.innerText.includes("Saved Markdown document: # Hello from MicroHttp"),
  );

  assert.equal(
    await page.locator("#markdown-field").inputValue(),
    "# Hello from MicroHttp\n\nEdit this Markdown document.",
  );

  await page.locator('.markdown-editor__toolbar button[data-mode="source"]').click();
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  assert.match(await sourceMarkdownValue(page), /# Hello from MicroHttp/);
  assert.match(await sourceMarkdownValue(page), /Edit this Markdown document\./);
  assert.equal(
    await page.locator('.markdown-editor__toolbar button[data-mode="source"]').getAttribute("aria-pressed"),
    "true",
  );
  await page.locator('.markdown-editor__toolbar button[data-mode="split"]').click();
  await page.waitForSelector(".markdown-editor__split .markdown-editor__preview h1");
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__preview h1").innerText(),
    "Hello from MicroHttp",
  );
  await page.locator('.markdown-editor__toolbar button[data-mode="visual"]').click();
  await page.waitForSelector(".markdown-editor__surface .ProseMirror");

  await page.goto(`${baseUrl}/documents/home/edit?mode=source`);
  await page.waitForSelector(".markdown-editor__source .cm-editor");
  await page.waitForSelector(".markdown-editor__preview h1");
  assert.equal(
    await page.locator(".markdown-editor__preview h1").innerText(),
    "Hello from MicroHttp",
  );

  await fillSourceMarkdown(page, ".markdown-editor__source", "<script>alert(1)</script>");
  await page.waitForSelector(".markdown-editor__error:not([hidden])");
  assert.equal(
    await page.locator(".markdown-editor__error").innerText(),
    "Unsupported Markdown node for editor subset: html",
  );

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
  await page.waitForFunction(() =>
    document
      .querySelector(".markdown-editor__preview")
      ?.innerText.includes("Exact source paragraph with link."),
  );
  assert.equal(await page.locator(".markdown-editor__preview p strong").first().innerText(), "source");
  assert.equal(await page.locator(".markdown-editor__preview p br").count(), 1);
  assert.equal(await page.locator(".markdown-editor__preview a").getAttribute("href"), "/target");
  assert.deepEqual(await page.locator(".markdown-editor__preview li").allInnerTexts(), [
    "first",
    "second",
  ]);
  assert.equal(await page.locator(".markdown-editor__preview blockquote strong").innerText(), "source");
  assert.equal(await page.locator(".markdown-editor__preview pre code").innerText(), "const value = 1;");
  assert.equal(
    await page.locator(".markdown-editor__preview pre code").getAttribute("class"),
    "language-typescript",
  );

  await page.getByRole("button", { name: "Save" }).click();
  await page.waitForFunction(() =>
    document
      .querySelector("#save-status")
      ?.innerText.includes("Saved Markdown document: # Source heading"),
  );

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
  await page.waitForSelector(".markdown-editor__split .markdown-editor__preview strong");
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__preview p strong").first().innerText(),
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
      .querySelector(".markdown-editor__split .markdown-editor__preview")
      ?.innerText.includes("Split source paragraph."),
  );
  assert.equal(
    await page.locator(".markdown-editor__split .markdown-editor__preview strong").innerText(),
    "source",
  );
  assert.deepEqual(
    await page.locator(".markdown-editor__split .markdown-editor__preview li").allInnerTexts(),
    ["first", "second"],
  );
  await page.waitForSelector(".markdown-editor__split .markdown-editor__preview hr");

  await page.getByRole("button", { name: "Save" }).click();
  await page.waitForFunction(() =>
    document
      .querySelector("#save-status")
      ?.innerText.includes("Saved Markdown document: # Split heading"),
  );
  assert.equal(await page.locator("#markdown-field").inputValue(), splitMarkdown);

  await page.goto(`${baseUrl}/documents/home`);
  assert.equal((await page.locator("body").innerText()).trim(), splitMarkdown);

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
  await page.waitForFunction(() =>
    document
      .querySelector("#save-status")
      ?.innerText.includes("Saved Markdown document: # Autosaved heading"),
  );
  assert.equal(await page.locator("#markdown-field").inputValue(), autosavedMarkdown);

  await page.goto(`${baseUrl}/documents/home`);
  assert.equal((await page.locator("body").innerText()).trim(), autosavedMarkdown);

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

async function sourceMarkdownValue(page) {
  return normaliseCodeMirrorText(await page.locator(".markdown-editor__source .cm-content").innerText());
}

function normaliseCodeMirrorText(text) {
  return text.replaceAll("\u00a0", " ");
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
