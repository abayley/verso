import type {
    Blockquote,
    Break,
    Code,
    Delete,
    Heading,
    InlineCode,
    Link,
    List,
    ListItem,
    Paragraph,
    PhrasingContent,
    RootContent,
    Strong,
    Text,
} from "mdast";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import { unified } from "unified";
import type { EditorBlock, EditorDocument, InlineNode, ListItemBlock } from "./editor-model.js";

/** Parses Markdown with remark and converts supported mdast nodes to the editor document model. */
export function parseMarkdownWithRemark(markdown: string): EditorDocument {
    const tree = unified().use(remarkParse).use(remarkGfm).parse(markdown);

    return {
        blocks: tree.children.map((node: RootContent): EditorBlock => blockFromMdast(node)),
    };
}

/** Converts a supported mdast block node into an editor block. */
function blockFromMdast(node: RootContent): EditorBlock {
    if (node.type === "heading") {
        return headingFromMdast(node);
    }

    if (node.type === "paragraph") {
        return paragraphFromMdast(node);
    }

    if (node.type === "list") {
        return listFromMdast(node);
    }

    if (node.type === "thematicBreak") {
        return {
            type: "horizontalRule",
        };
    }

    if (node.type === "code") {
        return codeBlockFromMdast(node);
    }

    if (node.type === "blockquote") {
        return blockquoteFromMdast(node);
    }

    throw unsupportedNode(node.type);
}

/** Converts a supported mdast blockquote node into an editor blockquote. */
function blockquoteFromMdast(node: Blockquote): EditorBlock {
    return {
        blocks: node.children.map((child: RootContent): EditorBlock => blockFromMdast(child)),
        type: "blockquote",
    };
}

/** Converts a supported mdast code node into an editor code block. */
function codeBlockFromMdast(node: Code): EditorBlock {
    return {
        language: node.lang ?? null,
        text: node.value,
        type: "codeBlock",
    };
}

/** Converts a supported mdast heading node into an editor heading. */
function headingFromMdast(node: Heading): EditorBlock {
    if (node.depth !== 1 && node.depth !== 2 && node.depth !== 3) {
        throw unsupportedNode(`heading:${node.depth}`);
    }

    return {
        children: inlineNodesFromMdast(node.children),
        level: node.depth,
        type: "heading",
    };
}

/** Converts a supported mdast paragraph node into an editor paragraph. */
function paragraphFromMdast(node: Paragraph): EditorBlock {
    return {
        children: inlineNodesFromMdast(node.children),
        type: "paragraph",
    };
}

/** Converts a supported mdast list node into an editor list. */
function listFromMdast(node: List): EditorBlock {
    return {
        items: node.children.map((item: ListItem): ListItemBlock => listItemFromMdast(item)),
        ordered: node.ordered === true,
        type: "list",
    };
}

/** Converts a supported mdast list item into editor item blocks. */
function listItemFromMdast(item: ListItem): ListItemBlock {
    if (item.children.length === 0) {
        throw unsupportedNode("listItem:empty");
    }

    return {
        blocks: item.children.map((child: RootContent): EditorBlock => blockFromMdast(child)),
    };
}

/** Converts supported mdast phrasing nodes into editor inline nodes. */
function inlineNodesFromMdast(nodes: PhrasingContent[]): InlineNode[] {
    return nodes.map((node: PhrasingContent): InlineNode => inlineNodeFromMdast(node));
}

/** Converts one supported mdast phrasing node into an editor inline node. */
function inlineNodeFromMdast(node: PhrasingContent): InlineNode {
    if (node.type === "text") {
        return textInlineFromMdast(node);
    }

    if (node.type === "strong") {
        return strongInlineFromMdast(node);
    }

    if (node.type === "emphasis") {
        return {
            children: inlineNodesFromMdast(node.children),
            type: "emphasis",
        };
    }

    if (node.type === "delete") {
        return strikethroughInlineFromMdast(node);
    }

    if (node.type === "inlineCode") {
        return codeInlineFromMdast(node);
    }

    if (node.type === "link") {
        return linkInlineFromMdast(node);
    }

    if (node.type === "break") {
        return breakInlineFromMdast(node);
    }

    throw unsupportedNode(node.type);
}

/** Converts a hard-break mdast node into an editor break node. */
function breakInlineFromMdast(_node: Break): InlineNode {
    return {
        type: "break",
    };
}

/** Converts a GFM delete mdast node into an editor strikethrough node. */
function strikethroughInlineFromMdast(node: Delete): InlineNode {
    return {
        children: inlineNodesFromMdast(node.children),
        type: "strikethrough",
    };
}

/** Converts a text mdast node into an editor text node. */
function textInlineFromMdast(node: Text): InlineNode {
    return {
        text: node.value,
        type: "text",
    };
}

/** Converts a strong mdast node into an editor strong node. */
function strongInlineFromMdast(node: Strong): InlineNode {
    return {
        children: inlineNodesFromMdast(node.children),
        type: "strong",
    };
}

/** Converts an inline code mdast node into an editor code node. */
function codeInlineFromMdast(node: InlineCode): InlineNode {
    return {
        text: node.value,
        type: "code",
    };
}

/** Converts a link mdast node into an editor link node. */
function linkInlineFromMdast(node: Link): InlineNode {
    return {
        children: inlineNodesFromMdast(node.children),
        type: "link",
        url: node.url,
    };
}

/** Builds an unsupported-node error for the current editor subset. */
function unsupportedNode(type: string): Error {
    return new Error(`Unsupported Markdown node for editor subset: ${type}`);
}
