// Lit decision-test spike (RFC-0002 follow-up). Throwaway: rebuilds the editor's
// command-bar toolbar, save-state view, and link popover declaratively in Lit,
// reusing the framework-agnostic SaveStateController and Web Awesome controls,
// to compare against the imperative custom-element shell. It does NOT wire real
// Tiptap/CodeMirror editing -- per the decision test, the adapters are unchanged
// and only the view layer is rebuilt. Findings: docs/design/markdown-editor-spike.md.
import { LitElement, html, nothing } from "lit";
import { SaveStateController, type SaveStateView } from "../../src/TestApp/Editor/save-state-controller.js";

interface BlockStyle {
    value: string;
    label: string;
}

interface InlineCommand {
    style: string;
    label: string;
    icon: string;
}

const BLOCK_STYLES: BlockStyle[] = [
    { value: "paragraph", label: "Paragraph" },
    { value: "heading-1", label: "Heading 1" },
    { value: "heading-2", label: "Heading 2" },
    { value: "heading-3", label: "Heading 3" },
];

const INLINE_COMMANDS: InlineCommand[] = [
    { style: "strong", label: "Bold", icon: "bold" },
    { style: "emphasis", label: "Italic", icon: "italic" },
    { style: "strikethrough", label: "Strike", icon: "strikethrough" },
    { style: "code", label: "Code", icon: "code" },
    { style: "link", label: "Link", icon: "link" },
];

const STRUCTURE_COMMANDS: InlineCommand[] = [
    { style: "bullet-list", label: "Bullet List", icon: "list" },
    { style: "ordered-list", label: "Ordered List", icon: "list-ol" },
    { style: "blockquote", label: "Blockquote", icon: "quote-left" },
    { style: "code-block", label: "Code Block", icon: "file-code" },
];

/**
 * The command-bar toolbar, save button, and link popover rendered declaratively.
 * Compare the single render() template below with the imperative equivalent in
 * markdown-editor-element.ts: createCommandBar + createStyleDropdown +
 * createInlineStyleButton + createStructureButton + createSaveButton +
 * updateToolbarState + applySaveView, plus the link-popover controller's DOM.
 */
export class EditorToolbarSpike extends LitElement {
    static properties = {
        save: { state: true },
        blockStyle: { state: true },
        activeMarks: { state: true },
        linkOpen: { state: true },
    };

    private save: SaveStateView = { state: "clean", buttonLabel: "Save", buttonDisabled: true, error: null };
    private blockStyle = "paragraph";
    private activeMarks: Record<string, boolean> = {};
    private linkOpen = false;
    private markdown = "# Lit spike\n\nEdit me.";
    private readonly controller = new SaveStateController(
        (): string => this.markdown,
        (view: SaveStateView): void => {
            this.save = view;
            this.requestUpdate();
        },
    );

    // Render into light DOM so Web Awesome's global control styles apply, exactly
    // as the production light-DOM custom element relies on them.
    protected createRenderRoot(): HTMLElement {
        return this;
    }

    private blockLabel(): string {
        return BLOCK_STYLES.find((style) => style.value === this.blockStyle)?.label ?? "Paragraph";
    }

    private applyBlock(value: string): void {
        this.blockStyle = value;
        this.requestUpdate();
    }

    private toggleInline(style: string): void {
        if (style === "link") {
            this.linkOpen = true;
            this.requestUpdate();
            return;
        }

        this.activeMarks = { ...this.activeMarks, [style]: !this.activeMarks[style] };
        this.requestUpdate();
    }

    private save_(): void {
        this.controller.markSaving();
        window.setTimeout((): void => this.controller.markSucceeded(), 300);
    }

    protected render(): unknown {
        return html`
            <div class="markdown-editor__toolbar markdown-editor__toolbar--commands" role="toolbar">
                <wa-dropdown class="markdown-editor__style-dropdown" size="small">
                    <wa-button slot="trigger" appearance="plain" size="small" with-caret>${this.blockLabel()}</wa-button>
                    ${BLOCK_STYLES.map(
                        (style) => html`
                            <wa-dropdown-item value=${style.value} @click=${(): void => this.applyBlock(style.value)}>
                                ${style.label}
                            </wa-dropdown-item>
                        `,
                    )}
                </wa-dropdown>
                <wa-button-group>
                    ${INLINE_COMMANDS.map(
                        (command) => html`
                            <wa-button
                                appearance="plain"
                                size="small"
                                aria-label=${command.label}
                                class=${this.activeMarks[command.style] ? "active" : ""}
                                @click=${(): void => this.toggleInline(command.style)}
                            >
                                <wa-icon name=${command.icon}></wa-icon>
                            </wa-button>
                        `,
                    )}
                </wa-button-group>
                <wa-button-group>
                    ${STRUCTURE_COMMANDS.map(
                        (command) => html`
                            <wa-button appearance="plain" size="small" aria-label=${command.label}>
                                <wa-icon name=${command.icon}></wa-icon>
                            </wa-button>
                        `,
                    )}
                </wa-button-group>
                <wa-button
                    type="submit"
                    appearance="plain"
                    size="small"
                    ?disabled=${this.save.buttonDisabled}
                    @click=${(): void => this.save_()}
                >
                    ${this.save.buttonLabel}
                </wa-button>
                <span class="markdown-editor__save-error" role="status" ?hidden=${this.save.error === null}>
                    ${this.save.error ?? nothing}
                </span>
            </div>
            ${this.linkOpen
                ? html`
                      <div class="markdown-editor__link-editor">
                          <input class="markdown-editor__link-target" type="url" placeholder="Link target" />
                          <wa-button appearance="plain" size="small" @click=${(): void => this.closeLink()}>Apply</wa-button>
                          <wa-button appearance="plain" size="small" @click=${(): void => this.closeLink()}>Cancel</wa-button>
                      </div>
                  `
                : nothing}
        `;
    }

    private closeLink(): void {
        this.linkOpen = false;
        this.requestUpdate();
    }
}

customElements.define("editor-toolbar-spike", EditorToolbarSpike);
