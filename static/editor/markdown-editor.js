(() => {
  // src/TestApp/Editor/markdown-parse.ts
  function parseMarkdown(markdown) {
    return {
      blocks: markdown.split(/\n{2,}/).map((block) => block.trim()).filter((block) => block.length > 0).map((block) => parseBlock(block))
    };
  }
  function parseBlock(block) {
    if (isHorizontalRuleBlock(block)) {
      return {
        type: "horizontalRule"
      };
    }
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
  function isHorizontalRuleBlock(block) {
    return /^ {0,3}([-*_])(?: ?\1){2,} *$/.test(block);
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
    if (block.type === "horizontalRule") {
      return "<hr>";
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
  function documentFromElements(elements) {
    return {
      blocks: Array.from(elements).map((element) => blockFromElement(element))
    };
  }
  function documentToMarkdown(document2) {
    return document2.blocks.map((block) => blockToMarkdown(block)).join(`

`);
  }
  function blockFromElement(block) {
    if (block.tagName === "HR") {
      return {
        type: "horizontalRule"
      };
    }
    if (block.tagName === "H1") {
      return {
        children: inlineNodesFromElement(block),
        level: 1,
        type: "heading"
      };
    }
    if (block.tagName === "H2") {
      return {
        children: inlineNodesFromElement(block),
        level: 2,
        type: "heading"
      };
    }
    if (block.tagName === "H3") {
      return {
        children: inlineNodesFromElement(block),
        level: 3,
        type: "heading"
      };
    }
    if (block.tagName === "UL") {
      return {
        items: Array.from(block.children).map((item) => inlineNodesFromElement(item)),
        ordered: false,
        type: "list"
      };
    }
    if (block.tagName === "OL") {
      return {
        items: Array.from(block.children).map((item) => inlineNodesFromElement(item)),
        ordered: true,
        type: "list"
      };
    }
    return {
      children: inlineNodesFromElement(block),
      type: "paragraph"
    };
  }
  function inlineNodesFromElement(element) {
    return Array.from(element.childNodes).flatMap((node) => inlineNodesFromNode(node));
  }
  function inlineNodesFromNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return textNode(node.textContent ?? "");
    }
    if (node.nodeType !== Node.ELEMENT_NODE) {
      return [];
    }
    const element = node;
    if (element.tagName === "STRONG" || element.tagName === "B") {
      return [
        {
          children: inlineNodesFromElement(element),
          type: "strong"
        }
      ];
    }
    if (element.tagName === "EM" || element.tagName === "I") {
      return [
        {
          children: inlineNodesFromElement(element),
          type: "emphasis"
        }
      ];
    }
    if (element.tagName === "CODE") {
      return [
        {
          text: element.innerText,
          type: "code"
        }
      ];
    }
    if (element.tagName === "A") {
      return [
        {
          children: inlineNodesFromElement(element),
          type: "link",
          url: element.getAttribute("href") ?? ""
        }
      ];
    }
    return inlineNodesFromElement(element);
  }
  function blockToMarkdown(block) {
    if (block.type === "horizontalRule") {
      return "---";
    }
    if (block.type === "heading") {
      return `${"#".repeat(block.level)} ${inlineNodesToMarkdown(block.children).trim()}`;
    }
    if (block.type === "list") {
      return block.items.map((item, index) => {
        const marker = block.ordered ? `${index + 1}.` : "-";
        return `${marker} ${inlineNodesToMarkdown(item).trim()}`;
      }).join(`
`);
    }
    return inlineNodesToMarkdown(block.children).trim();
  }
  function inlineNodesToMarkdown(nodes) {
    return nodes.map((node) => inlineNodeToMarkdown(node)).join("");
  }
  function inlineNodeToMarkdown(node) {
    if (node.type === "strong") {
      return `**${inlineNodesToMarkdown(node.children)}**`;
    }
    if (node.type === "emphasis") {
      return `*${inlineNodesToMarkdown(node.children)}*`;
    }
    if (node.type === "code") {
      return `\`${node.text}\``;
    }
    if (node.type === "link") {
      return `[${inlineNodesToMarkdown(node.children)}](${node.url})`;
    }
    return node.text;
  }
  function textNode(text) {
    if (text.length === 0) {
      return [];
    }
    return [
      {
        text,
        type: "text"
      }
    ];
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
      return documentToMarkdown(documentFromElements(this.editor.children));
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
