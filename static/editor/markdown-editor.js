(() => {
  // src/TestApp/Editor/markdown-parse.ts
  function parseMarkdown(markdown) {
    return {
      blocks: markdown.split(/\n{2,}/).map((block) => block.trim()).filter((block) => block.length > 0).map((block) => parseBlock(block))
    };
  }
  function parseBlock(block) {
    if (isUnorderedListBlock(block)) {
      return {
        items: block.split(`
`).map((line) => parseInlineMarkdown(line.trim().slice(2))),
        ordered: false,
        type: "list"
      };
    }
    if (isOrderedListBlock(block)) {
      return {
        items: block.split(`
`).map((line) => parseInlineMarkdown(orderedItemText(line))),
        ordered: true,
        type: "list"
      };
    }
    if (block.startsWith("### ")) {
      return {
        children: parseInlineMarkdown(block.slice(4)),
        level: 3,
        type: "heading"
      };
    }
    if (block.startsWith("## ")) {
      return {
        children: parseInlineMarkdown(block.slice(3)),
        level: 2,
        type: "heading"
      };
    }
    if (block.startsWith("# ")) {
      return {
        children: parseInlineMarkdown(block.slice(2)),
        level: 1,
        type: "heading"
      };
    }
    return {
      children: parseInlineMarkdown(block),
      type: "paragraph"
    };
  }
  function parseInlineMarkdown(markdown) {
    const nodes = [];
    let text = "";
    let remaining = markdown;
    while (remaining.length > 0) {
      if (remaining.startsWith("**")) {
        const parsed = takeDelimited(remaining.slice(2), "**");
        if (parsed) {
          appendText(nodes, text);
          text = "";
          nodes.push({
            children: parseInlineMarkdown(parsed.value),
            type: "strong"
          });
          remaining = parsed.rest;
          continue;
        }
      }
      if (remaining.startsWith("*")) {
        const parsed = takeDelimited(remaining.slice(1), "*");
        if (parsed) {
          appendText(nodes, text);
          text = "";
          nodes.push({
            children: parseInlineMarkdown(parsed.value),
            type: "emphasis"
          });
          remaining = parsed.rest;
          continue;
        }
      }
      if (remaining.startsWith("`")) {
        const parsed = takeDelimited(remaining.slice(1), "`");
        if (parsed) {
          appendText(nodes, text);
          text = "";
          nodes.push({
            text: parsed.value,
            type: "code"
          });
          remaining = parsed.rest;
          continue;
        }
      }
      if (remaining.startsWith("[")) {
        const parsed = takeLink(remaining.slice(1));
        if (parsed) {
          appendText(nodes, text);
          text = "";
          nodes.push({
            children: parseInlineMarkdown(parsed.label),
            type: "link",
            url: parsed.url
          });
          remaining = parsed.rest;
          continue;
        }
      }
      text += remaining[0] ?? "";
      remaining = remaining.slice(1);
    }
    appendText(nodes, text);
    return nodes;
  }
  function appendText(nodes, text) {
    if (text.length === 0) {
      return;
    }
    nodes.push({
      text,
      type: "text"
    });
  }
  function takeDelimited(markdown, delimiter) {
    const end = markdown.indexOf(delimiter);
    if (end < 0) {
      return null;
    }
    return {
      value: markdown.slice(0, end),
      rest: markdown.slice(end + delimiter.length)
    };
  }
  function takeLink(markdown) {
    const labelEnd = markdown.indexOf("](");
    if (labelEnd < 0) {
      return null;
    }
    const rest = markdown.slice(labelEnd + 2);
    const urlEnd = rest.indexOf(")");
    if (urlEnd < 0) {
      return null;
    }
    return {
      label: markdown.slice(0, labelEnd),
      url: rest.slice(0, urlEnd),
      rest: rest.slice(urlEnd + 1)
    };
  }
  function isUnorderedListBlock(block) {
    return block.split(`
`).every((line) => /^[-*+] .+/.test(line.trim()));
  }
  function isOrderedListBlock(block) {
    return block.split(`
`).every((line) => /^\d+\. .+/.test(line.trim()));
  }
  function orderedItemText(line) {
    return line.trim().replace(/^\d+\. /, "");
  }

  // src/TestApp/Editor/markdown-render.ts
  function renderMarkdown(markdown) {
    return renderEditorDocument(parseMarkdown(markdown));
  }
  function renderEditorDocument(document2) {
    return document2.blocks.map((block) => renderBlock(block)).join("");
  }
  function renderBlock(block) {
    if (block.type === "heading") {
      return `<h${block.level}>${renderInlineNodes(block.children)}</h${block.level}>`;
    }
    if (block.type === "list") {
      const tag = block.ordered ? "ol" : "ul";
      return `<${tag}>${block.items.map((item) => `<li>${renderInlineNodes(item)}</li>`).join("")}</${tag}>`;
    }
    return `<p>${renderInlineNodes(block.children)}</p>`;
  }
  function renderInlineNodes(nodes) {
    return nodes.map((node) => renderInlineNode(node)).join("");
  }
  function renderInlineNode(node) {
    if (node.type === "strong") {
      return `<strong>${renderInlineNodes(node.children)}</strong>`;
    }
    if (node.type === "emphasis") {
      return `<em>${renderInlineNodes(node.children)}</em>`;
    }
    if (node.type === "code") {
      return `<code>${escapeHtml(node.text)}</code>`;
    }
    if (node.type === "link") {
      return `<a href="${escapeHtml(node.url)}">${renderInlineNodes(node.children)}</a>`;
    }
    return escapeHtml(node.text);
  }
  function escapeHtml(value) {
    return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;").replaceAll("'", "&#39;");
  }

  // src/TestApp/Editor/markdown-serialise.ts
  function blockToMarkdown(block) {
    const text = inlineNodesToMarkdown(block).trim();
    if (block.tagName === "H1") {
      return `# ${text}`;
    }
    if (block.tagName === "H2") {
      return `## ${text}`;
    }
    if (block.tagName === "H3") {
      return `### ${text}`;
    }
    if (block.tagName === "UL") {
      return Array.from(block.children).map((item) => `- ${inlineNodesToMarkdown(item).trim()}`).join(`
`);
    }
    if (block.tagName === "OL") {
      return Array.from(block.children).map((item, index) => `${index + 1}. ${inlineNodesToMarkdown(item).trim()}`).join(`
`);
    }
    return text;
  }
  function inlineNodesToMarkdown(element) {
    return Array.from(element.childNodes).map((node) => inlineNodeToMarkdown(node)).join("");
  }
  function inlineNodeToMarkdown(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent ?? "";
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return "";
    }
    const element = node;
    if (element.tagName === "STRONG" || element.tagName === "B") {
      return `**${inlineNodesToMarkdown(element)}**`;
    }
    if (element.tagName === "EM" || element.tagName === "I") {
      return `*${inlineNodesToMarkdown(element)}*`;
    }
    if (element.tagName === "CODE") {
      return `\`${element.innerText}\``;
    }
    if (element.tagName === "A") {
      return `[${inlineNodesToMarkdown(element)}](${element.getAttribute("href") ?? ""})`;
    }
    return inlineNodesToMarkdown(element);
  }

  // src/TestApp/Editor/markdown-editor-element.ts
  class MarkdownEditorElement extends HTMLElement {
    editor = null;
    initialised = false;
    markdown = "";
    mode = "visual";
    panes = null;
    preview = null;
    source = null;
    connectedCallback() {
      if (this.initialised) {
        return;
      }
      window.setTimeout(() => {
        this.initialise().catch((error) => {
          console.error(error);
        });
      }, 0);
    }
    async initialise() {
      if (this.initialised) {
        return;
      }
      this.initialised = true;
      this.markdown = await this.loadMarkdown();
      this.mode = this.editorMode();
      this.textContent = "";
      if (this.mode === "source" || this.mode === "split") {
        this.source = document.createElement("textarea");
        this.source.className = "markdown-editor__source";
        this.source.value = this.markdown;
        this.source.addEventListener("input", () => this.handleInput());
      }
      if (this.mode === "visual") {
        this.editor = document.createElement("div");
        this.editor.className = "markdown-editor__surface";
        this.editor.contentEditable = "true";
        this.editor.innerHTML = renderMarkdown(this.markdown);
        this.editor.addEventListener("input", () => this.handleInput());
      }
      this.preview = document.createElement("div");
      this.preview.className = "markdown-editor__preview";
      this.preview.setAttribute("aria-live", "polite");
      if (this.mode === "split") {
        this.panes = document.createElement("div");
        this.panes.className = "markdown-editor__split";
        this.panes.append(this.sourceElement(), this.preview);
        this.append(this.panes);
      } else {
        this.append(this.source ?? this.editorElement(), this.preview);
      }
      this.updatePreview();
      this.configureFormSubmission();
    }
    editorMode() {
      const mode = this.getAttribute("mode");
      if (mode === "source" || mode === "split") {
        return mode;
      }
      return "visual";
    }
    async loadMarkdown() {
      const src = this.getAttribute("src");
      if (!src) {
        return this.textContent.trim();
      }
      const response = await fetch(src, {
        headers: {
          Accept: "text/markdown"
        }
      });
      if (!response.ok) {
        throw new Error(`Failed to load Markdown document: ${response.status}`);
      }
      return response.text();
    }
    toMarkdown() {
      if (this.source) {
        return this.source.value;
      }
      if (!this.editor) {
        return this.markdown;
      }
      return Array.from(this.editor.children).map((child) => blockToMarkdown(child)).join(`

`);
    }
    updatePreview() {
      if (!this.preview) {
        return;
      }
      this.preview.innerHTML = renderMarkdown(this.toMarkdown());
    }
    handleInput() {
      const markdown = this.toMarkdown();
      this.updatePreview();
      this.dispatchEvent(new CustomEvent("editor:changed", {
        bubbles: true,
        detail: {
          markdown
        }
      }));
    }
    configureFormSubmission() {
      const form = this.closest("form");
      const field = document.getElementById("markdown-field");
      if (!(form instanceof HTMLFormElement) || !(field instanceof HTMLInputElement)) {
        return;
      }
      form.addEventListener("htmx:configRequest", (event) => {
        const markdown = this.toMarkdown();
        const htmxEvent = event;
        field.value = markdown;
        htmxEvent.detail.parameters["markdown"] = markdown;
      });
    }
    editorElement() {
      if (!this.editor) {
        throw new Error("Markdown editor surface was not created.");
      }
      return this.editor;
    }
    sourceElement() {
      if (!this.source) {
        throw new Error("Markdown source textarea was not created.");
      }
      return this.source;
    }
  }

  // src/TestApp/Editor/index.ts
  if (!customElements.get("markdown-editor")) {
    customElements.define("markdown-editor", MarkdownEditorElement);
  }
})();
