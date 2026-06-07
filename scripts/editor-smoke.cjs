const assert = require("node:assert/strict");
const { spawn } = require("node:child_process");
const http = require("node:http");
const { chromium } = require("playwright");

const baseUrl = "http://127.0.0.1:8080";

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

    stopServer();
  });

async function main() {
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

  await page.goto(`${baseUrl}/documents/home/edit?mode=source`);
  await page.waitForSelector(".markdown-editor__source");

  const sourceMarkdown = "# Source heading\n\nExact source paragraph.";
  await page.locator(".markdown-editor__source").fill(sourceMarkdown);
  await page.getByRole("button", { name: "Save" }).click();
  await page.waitForFunction(() =>
    document
      .querySelector("#save-status")
      ?.innerText.includes("Saved Markdown document: # Source heading"),
  );

  assert.equal(await page.locator("#markdown-field").inputValue(), sourceMarkdown);
  assert.deepEqual(consoleErrors, []);
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
  if (!serverProcess || serverProcess.killed) {
    return;
  }

  try {
    process.kill(-serverProcess.pid, "SIGTERM");
  } catch (_err) {
    serverProcess.kill("SIGTERM");
  }
}
