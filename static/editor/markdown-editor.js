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
    this.textContent = "";
    this.editor = document.createElement("div");
    this.editor.className = "markdown-editor__surface";
    this.editor.contentEditable = "true";
    this.editor.innerHTML = this.renderMarkdown(this.markdown);
    this.append(this.editor);

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
    if (block.startsWith("### ")) {
      return `<h3>${this.escapeHtml(block.slice(4))}</h3>`;
    }

    if (block.startsWith("## ")) {
      return `<h2>${this.escapeHtml(block.slice(3))}</h2>`;
    }

    if (block.startsWith("# ")) {
      return `<h1>${this.escapeHtml(block.slice(2))}</h1>`;
    }

    return `<p>${this.escapeHtml(block)}</p>`;
  }

  blockToMarkdown(block) {
    const text = block.innerText.trim();

    if (block.tagName === "H1") {
      return `# ${text}`;
    }

    if (block.tagName === "H2") {
      return `## ${text}`;
    }

    if (block.tagName === "H3") {
      return `### ${text}`;
    }

    return text;
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
