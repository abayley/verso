// Studio interaction spike (RFC-0015, deferred theme C). Throwaway prototype:
// proves a selection bubble toolbar and a slash command menu over the same
// Tiptap the editor already uses, with no Tiptap menu package and no Lit --
// positioning is done by hand, the way the editor's link popovers already are.
// Findings: docs/design/editor-studio-spike.md.
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";

const mount = requireElement("editor");
const bubble = requireElement("bubble");
const slash = requireElement("slash");

const editor = new Editor({
    element: mount,
    extensions: [StarterKit],
    content:
        "<h1>Studio spike</h1><p>Select some words to raise the bubble toolbar. " +
        "On a new empty line, type <code>/</code> to open the slash menu.</p>",
    onSelectionUpdate: ({ editor }) => updateBubble(editor),
    onUpdate: ({ editor }) => {
        updateBubble(editor);
        updateSlash(editor);
    },
    onTransaction: ({ editor }) => updateBubble(editor),
});

// --- Bubble toolbar: shown over a non-empty selection. ---

interface BubbleAction {
    label: string;
    run: () => void;
    active: () => boolean;
}

const bubbleActions: BubbleAction[] = [
    { label: "B", run: () => editor.chain().focus().toggleBold().run(), active: () => editor.isActive("bold") },
    { label: "I", run: () => editor.chain().focus().toggleItalic().run(), active: () => editor.isActive("italic") },
    { label: "S", run: () => editor.chain().focus().toggleStrike().run(), active: () => editor.isActive("strike") },
    { label: "</>", run: () => editor.chain().focus().toggleCode().run(), active: () => editor.isActive("code") },
];

for (const action of bubbleActions) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = action.label;
    button.addEventListener("mousedown", (event) => event.preventDefault());
    button.addEventListener("click", () => {
        action.run();
        updateBubble(editor);
    });
    bubble.append(button);
}

function updateBubble(active: Editor): void {
    const { from, to, empty } = active.state.selection;

    // A real build also gates on active.isFocused; it is omitted here only so the
    // bubble can be exercised in a headless browser that lacks window focus.
    if (empty || from === to) {
        bubble.hidden = true;
        return;
    }

    const start = active.view.coordsAtPos(from);
    const end = active.view.coordsAtPos(to);
    const centre = (start.left + end.right) / 2;

    bubble.hidden = false;
    bubble.style.left = `${centre + window.scrollX}px`;
    bubble.style.top = `${start.top + window.scrollY - bubble.offsetHeight - 8}px`;

    bubble.querySelectorAll("button").forEach((button, index) => {
        button.classList.toggle("active", bubbleActions[index]?.active() ?? false);
    });
}

// --- Slash menu: shown when a block is exactly "/". ---

interface SlashCommand {
    label: string;
    run: () => void;
}

const slashCommands: SlashCommand[] = [
    { label: "Heading 1", run: () => replaceSlash((chain) => chain.setHeading({ level: 1 })) },
    { label: "Heading 2", run: () => replaceSlash((chain) => chain.setHeading({ level: 2 })) },
    { label: "Bullet list", run: () => replaceSlash((chain) => chain.toggleBulletList()) },
    { label: "Numbered list", run: () => replaceSlash((chain) => chain.toggleOrderedList()) },
    { label: "Quote", run: () => replaceSlash((chain) => chain.toggleBlockquote()) },
    { label: "Code block", run: () => replaceSlash((chain) => chain.toggleCodeBlock()) },
];

let slashIndex = 0;

for (const command of slashCommands) {
    const item = document.createElement("button");
    item.type = "button";
    item.textContent = command.label;
    item.addEventListener("mousedown", (event) => event.preventDefault());
    item.addEventListener("click", () => command.run());
    slash.append(item);
}

function slashIsOpen(): boolean {
    return !slash.hidden;
}

function updateSlash(active: Editor): void {
    const { $from, empty } = active.state.selection;

    if (!empty || $from.parent.textContent !== "/" || !$from.parent.isTextblock) {
        closeSlash();
        return;
    }

    const at = active.view.coordsAtPos($from.pos);
    slash.hidden = false;
    slash.style.left = `${at.left + window.scrollX}px`;
    slash.style.top = `${at.bottom + window.scrollY + 6}px`;
    slashIndex = 0;
    highlightSlash();
}

function replaceSlash(apply: (chain: ReturnType<Editor["chain"]>) => ReturnType<Editor["chain"]>): void {
    const { $from } = editor.state.selection;
    const start = $from.start();
    const chain = editor.chain().focus().deleteRange({ from: start, to: start + 1 });
    apply(chain).run();
    closeSlash();
}

function closeSlash(): void {
    slash.hidden = true;
}

function highlightSlash(): void {
    slash.querySelectorAll("button").forEach((button, index) => {
        button.classList.toggle("active", index === slashIndex);
    });
}

// Keyboard navigation for the slash menu, captured before ProseMirror.
mount.addEventListener(
    "keydown",
    (event: KeyboardEvent) => {
        if (!slashIsOpen()) {
            return;
        }

        if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            const delta = event.key === "ArrowDown" ? 1 : -1;
            slashIndex = (slashIndex + delta + slashCommands.length) % slashCommands.length;
            highlightSlash();
        } else if (event.key === "Enter") {
            event.preventDefault();
            slashCommands[slashIndex]?.run();
        } else if (event.key === "Escape") {
            closeSlash();
        }
    },
    true,
);

// Exposed for the spike's browser checks only.
(globalThis as unknown as { __studioEditor: Editor }).__studioEditor = editor;

function requireElement(id: string): HTMLElement {
    const element = document.getElementById(id);

    if (!element) {
        throw new Error(`Missing #${id}`);
    }

    return element;
}
