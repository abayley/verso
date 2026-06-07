class MarkdownEditor extends HTMLElement {
  connectedCallback() {
    if (this.initialised) {
      return;
    }

    window.setTimeout(() => this.initialise(), 0);
  }

  initialise() {
    if (this.initialised) {
      return;
    }

    this.initialised = true;
    this.markdown = this.textContent.trim();
    this.mode = this.getAttribute("mode") || "visual";
    this.textContent = "";

    if (this.mode === "source") {
      this.source = document.createElement("textarea");
      this.source.className = "markdown-editor__source";
      this.source.value = this.markdown;
      this.append(this.source);
    } else {
      this.editor = document.createElement("div");
      this.editor.className = "markdown-editor__surface";
      this.editor.contentEditable = "true";
      this.editor.innerHTML = this.renderMarkdown(this.markdown);
      this.append(this.editor);
    }

    const form = this.closest("form");
    const field = document.getElementById("markdown-field");

    if (form && field) {
      form.addEventListener("htmx:configRequest", (event) => {
        const markdown = this.toMarkdown();

        field.value = markdown;
        event.detail.parameters.markdown = markdown;
      });
    }
  }

  toMarkdown() {
    if (this.source) {
      return this.source.value;
    }

    if (!this.editor) {
      return this.markdown;
    }

    return Array.from(this.editor.children)
      .map((child) => this.blockToMarkdown(child))
      .join("\n\n");
  }

  renderMarkdown(markdown) {
    return markdown
      .split(/\n{2,}/)
      .map((block) => this.renderBlock(block.trim()))
      .join("");
  }

  renderBlock(block) {
    if (this.isUnorderedListBlock(block)) {
      return `<ul>${block
        .split("\n")
        .map((line) => `<li>${this.renderInlineMarkdown(line.trim().slice(2))}</li>`)
        .join("")}</ul>`;
    }

    if (this.isOrderedListBlock(block)) {
      return `<ol>${block
        .split("\n")
        .map((line) => `<li>${this.renderInlineMarkdown(this.orderedItemText(line))}</li>`)
        .join("")}</ol>`;
    }

    if (block.startsWith("### ")) {
      return `<h3>${this.renderInlineMarkdown(block.slice(4))}</h3>`;
    }

    if (block.startsWith("## ")) {
      return `<h2>${this.renderInlineMarkdown(block.slice(3))}</h2>`;
    }

    if (block.startsWith("# ")) {
      return `<h1>${this.renderInlineMarkdown(block.slice(2))}</h1>`;
    }

    return `<p>${this.renderInlineMarkdown(block)}</p>`;
  }

  blockToMarkdown(block) {
    const text = this.inlineNodesToMarkdown(block).trim();

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
      return Array.from(block.children)
        .map((item) => `- ${this.inlineNodesToMarkdown(item).trim()}`)
        .join("\n");
    }

    if (block.tagName === "OL") {
      return Array.from(block.children)
        .map((item, index) => `${index + 1}. ${this.inlineNodesToMarkdown(item).trim()}`)
        .join("\n");
    }

    return text;
  }

  renderInlineMarkdown(markdown) {
    let html = "";
    let remaining = markdown;

    while (remaining.length > 0) {
      if (remaining.startsWith("**")) {
        const parsed = this.takeDelimited(remaining.slice(2), "**");
        if (parsed) {
          html += `<strong>${this.renderInlineMarkdown(parsed.value)}</strong>`;
          remaining = parsed.rest;
          continue;
        }
      }

      if (remaining.startsWith("*")) {
        const parsed = this.takeDelimited(remaining.slice(1), "*");
        if (parsed) {
          html += `<em>${this.renderInlineMarkdown(parsed.value)}</em>`;
          remaining = parsed.rest;
          continue;
        }
      }

      if (remaining.startsWith("`")) {
        const parsed = this.takeDelimited(remaining.slice(1), "`");
        if (parsed) {
          html += `<code>${this.escapeHtml(parsed.value)}</code>`;
          remaining = parsed.rest;
          continue;
        }
      }

      if (remaining.startsWith("[")) {
        const parsed = this.takeLink(remaining.slice(1));
        if (parsed) {
          html += `<a href="${this.escapeHtml(parsed.url)}">${this.renderInlineMarkdown(
            parsed.label,
          )}</a>`;
          remaining = parsed.rest;
          continue;
        }
      }

      html += this.escapeHtml(remaining[0]);
      remaining = remaining.slice(1);
    }

    return html;
  }

  takeDelimited(markdown, delimiter) {
    const end = markdown.indexOf(delimiter);

    if (end < 0) {
      return null;
    }

    return {
      value: markdown.slice(0, end),
      rest: markdown.slice(end + delimiter.length),
    };
  }

  takeLink(markdown) {
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
      rest: rest.slice(urlEnd + 1),
    };
  }

  inlineNodesToMarkdown(element) {
    return Array.from(element.childNodes)
      .map((node) => this.inlineNodeToMarkdown(node))
      .join("");
  }

  inlineNodeToMarkdown(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent;
    }

    if (node.nodeType !== Node.ELEMENT_NODE) {
      return "";
    }

    if (node.tagName === "STRONG" || node.tagName === "B") {
      return `**${this.inlineNodesToMarkdown(node)}**`;
    }

    if (node.tagName === "EM" || node.tagName === "I") {
      return `*${this.inlineNodesToMarkdown(node)}*`;
    }

    if (node.tagName === "CODE") {
      return `\`${node.innerText}\``;
    }

    if (node.tagName === "A") {
      return `[${this.inlineNodesToMarkdown(node)}](${node.getAttribute("href") || ""})`;
    }

    return this.inlineNodesToMarkdown(node);
  }

  isUnorderedListBlock(block) {
    return block.split("\n").every((line) => /^[-*+] .+/.test(line.trim()));
  }

  isOrderedListBlock(block) {
    return block.split("\n").every((line) => /^\d+\. .+/.test(line.trim()));
  }

  orderedItemText(line) {
    return line.trim().replace(/^\d+\. /, "");
  }

  escapeHtml(value) {
    return value
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll("\"", "&quot;")
      .replaceAll("'", "&#39;");
  }
}

customElements.define("markdown-editor", MarkdownEditor);
