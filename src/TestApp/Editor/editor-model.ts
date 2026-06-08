export interface EditorDocument {
    blocks: EditorBlock[];
}

export type EditorBlock = BlockquoteBlock | CodeBlock | HeadingBlock | HorizontalRuleBlock | ListBlock | ParagraphBlock;

interface BlockquoteBlock {
    blocks: EditorBlock[];
    type: "blockquote";
}

interface CodeBlock {
    language: string | null;
    text: string;
    type: "codeBlock";
}

interface HeadingBlock {
    children: InlineNode[];
    level: 1 | 2 | 3;
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

export type InlineNode = BreakInline | CodeInline | EmphasisInline | LinkInline | StrongInline | TextInline;

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

interface CodeInline {
    text: string;
    type: "code";
}

interface LinkInline {
    children: InlineNode[];
    type: "link";
    url: string;
}
