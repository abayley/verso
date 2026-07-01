import type { VisualInlineStyle, VisualStructureStyle } from "./tiptap-visual-editor.js";

/** The `wa-select` event shape emitted by a Web Awesome dropdown. */
export interface WaDropdownSelectEvent extends Event {
    detail: {
        item: Element;
    };
}

/** An inline command button shared by the command bar and the bubble toolbar. */
export interface InlineCommand {
    style: VisualInlineStyle;
    label: string;
    icon: string;
    shortcut: string;
}

/** The block styles offered by the style dropdowns, in dropdown order; the first is the default. */
export const BLOCK_STYLES: { value: string; label: string }[] = [
    { value: "paragraph", label: "Paragraph" },
    { value: "heading-1", label: "Heading 1" },
    { value: "heading-2", label: "Heading 2" },
    { value: "heading-3", label: "Heading 3" },
    { value: "heading-4", label: "Heading 4" },
    { value: "heading-5", label: "Heading 5" },
    { value: "heading-6", label: "Heading 6" },
];

/** The inline command buttons, with the keymap suffix used to build the tooltip shortcut. */
export const INLINE_COMMANDS: InlineCommand[] = [
    { style: "strong", label: "Bold", icon: "bold", shortcut: "B" },
    { style: "emphasis", label: "Italic", icon: "italic", shortcut: "I" },
    { style: "strikethrough", label: "Strike", icon: "strikethrough", shortcut: "Shift+S" },
    { style: "code", label: "Code", icon: "code", shortcut: "E" },
    { style: "link", label: "Link", icon: "link", shortcut: "K" },
];

/** A structural command button shared by the command bar and the bubble toolbar. */
export interface StructureCommand {
    style: VisualStructureStyle;
    label: string;
    icon: string;
}

/** The structural command buttons, in toolbar order. */
export const STRUCTURE_COMMANDS: StructureCommand[] = [
    { style: "bullet-list", label: "Bullet List", icon: "list" },
    { style: "ordered-list", label: "Ordered List", icon: "list-ol" },
    { style: "blockquote", label: "Blockquote", icon: "quote-left" },
    { style: "code-block", label: "Code Block", icon: "file-code" },
    { style: "thematic-break", label: "Horizontal rule", icon: "window-minimize" },
];

/** Returns the display label for a block style value, defaulting to Paragraph. */
export function blockLabel(style: string): string {
    return BLOCK_STYLES.find((entry) => entry.value === style)?.label ?? "Paragraph";
}

/** Returns the platform-specific primary command modifier label. */
function primaryModifierLabel(): string {
    return /\bMac/.test(navigator.platform) ? "Cmd" : "Ctrl";
}

/** Builds the tooltip shortcut label for an inline command. */
export function inlineShortcut(command: InlineCommand): string {
    return `${primaryModifierLabel()}+${command.shortcut}`;
}

/** Suppresses the default mousedown so a toolbar press does not steal the editor selection. */
export function preventDefault(event: Event): void {
    event.preventDefault();
}

/** Reads the string value from an HTML or custom form control host. */
export function elementValue(element: HTMLElement): string {
    const value = (element as HTMLElement & { value?: unknown }).value;

    if (typeof value === "string") {
        return value;
    }

    return element.getAttribute("value") ?? "";
}
