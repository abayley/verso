export interface EditorDocument {
    blocks: EditorBlock[];
}

export type EditorBlock = BlockquoteBlock | CodeBlock | HeadingBlock | HorizontalRuleBlock | ListBlock | ParagraphBlock;

export interface BlockquoteBlock {
    blocks: EditorBlock[];
    type: "blockquote";
}

export interface CodeBlock {
    language: string | null;
    text: string;
    type: "codeBlock";
}

export interface HeadingBlock {
    children: InlineNode[];
    level: 1 | 2 | 3;
    type: "heading";
}

export interface ParagraphBlock {
    children: InlineNode[];
    type: "paragraph";
}

export interface ListBlock {
    items: InlineNode[][];
    ordered: boolean;
    type: "list";
}

export interface HorizontalRuleBlock {
    type: "horizontalRule";
}

export type InlineNode = CodeInline | EmphasisInline | LinkInline | StrongInline | TextInline;

export interface TextInline {
    text: string;
    type: "text";
}

export interface StrongInline {
    children: InlineNode[];
    type: "strong";
}

export interface EmphasisInline {
    children: InlineNode[];
    type: "emphasis";
}

export interface CodeInline {
    text: string;
    type: "code";
}

export interface LinkInline {
    children: InlineNode[];
    type: "link";
    url: string;
}
