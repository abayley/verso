export interface EditorDocument {
    blocks: EditorBlock[];
}

declare const contentExtensionPayloads: unique symbol;

/** Extension-owned payloads, augmented by each in-tree content extension. */
export interface ContentExtensionPayloads {
    readonly [contentExtensionPayloads]?: never;
}

/** The names contributed to the open content extension payload map. */
export type ContentExtensionName = keyof ContentExtensionPayloads & string;

/** The block payload owned by one named content extension. */
export type ContentExtensionBlockPayload<Name extends ContentExtensionName> = Name extends ContentExtensionName
    ? ContentExtensionPayloads[Name] extends { block: infer Payload }
        ? Payload
        : never
    : never;

/** The inline payload owned by one named content extension. */
export type ContentExtensionInlinePayload<Name extends ContentExtensionName> = Name extends ContentExtensionName
    ? ContentExtensionPayloads[Name] extends { inline: infer Payload }
        ? Payload
        : never
    : never;

export type EditorBlock =
    | BlockquoteBlock
    | CodeBlock
    | CustomBlock
    | HeadingBlock
    | HorizontalRuleBlock
    | ListBlock
    | ParagraphBlock;

interface BlockquoteBlock {
    blocks: EditorBlock[];
    type: "blockquote";
}

interface CodeBlock {
    language: string | null;
    text: string;
    type: "codeBlock";
}

/** The Markdown heading levels the editor supports (`#` to `######`). */
export type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;

interface HeadingBlock {
    children: InlineNode[];
    level: HeadingLevel;
    type: "heading";
}

interface ParagraphBlock {
    children: InlineNode[];
    type: "paragraph";
}

interface ListBlock {
    items: ListItemBlock[];
    ordered: boolean;
    type: "list";
}

export interface ListItemBlock {
    blocks: EditorBlock[];
}

interface HorizontalRuleBlock {
    type: "horizontalRule";
}

/** A block contributed by a content extension; its payload is owned and validated by that extension. */
export interface CustomBlock<Name extends ContentExtensionName = ContentExtensionName> {
    children?: EditorBlock[];
    data: ContentExtensionBlockPayload<Name>;
    extension: Name;
    type: "custom";
}

export type InlineNode =
    | BreakInline
    | CodeInline
    | CustomInline
    | EmphasisInline
    | LinkInline
    | StrikethroughInline
    | StrongInline
    | TextInline;

/** An inline node contributed by a content extension; its payload is owned and validated by that extension. */
export interface CustomInline<Name extends ContentExtensionName = ContentExtensionName> {
    children?: InlineNode[];
    data: ContentExtensionInlinePayload<Name>;
    extension: Name;
    type: "custom";
}

interface BreakInline {
    type: "break";
}

interface TextInline {
    text: string;
    type: "text";
}

interface StrongInline {
    children: InlineNode[];
    type: "strong";
}

interface EmphasisInline {
    children: InlineNode[];
    type: "emphasis";
}

interface StrikethroughInline {
    children: InlineNode[];
    type: "strikethrough";
}

interface CodeInline {
    text: string;
    type: "code";
}

interface LinkInline {
    children: InlineNode[];
    type: "link";
    url: string;
}
