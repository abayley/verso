import type { Nodes, PhrasingContent, Root } from "mdast";
import type { Plugin } from "unified";
import type { ContentExtension, FromElementContext, ParseContext, ToMarkdownContext } from "./content-extension.js";
import type { EditorBlock, InlineNode } from "./editor-model.js";

/** The payload on a custom image inline node. */
interface ImageData {
    alt: string;
    src: string;
    title: string | null;
    /** Display width in pixels from a `{width=N}` attribute, or null when unsized. */
    width: number | null;
}

/** A width attached to an mdast image node by the attribute-parsing transform. */
interface ImageWidthData {
    width?: number;
}

/**
 * Parses a Pandoc-style attribute list (`{width=N}`) that immediately follows an image and attaches the
 * width to the image node. Markdown has no native image-size syntax and the project rejects raw `<img>`
 * HTML (ADR-040/041), so the size travels as a documented Markdown attribute list. remark parses the
 * `{width=N}` as literal text after the image; this transform consumes that text and lifts the width onto
 * the image's `data`, where {@link inlineFromMdast} reads it.
 */
const remarkImageWidth: Plugin<[], Root> = () => {
    return (tree: Root): void => {
        applyImageWidths(tree);
    };
};

/** Walks the tree, applying `{width=N}` attribute lists that follow image nodes. */
function applyImageWidths(node: Nodes): void {
    if (!("children" in node)) {
        return;
    }

    const children = node.children;

    for (let index = 0; index < children.length; index += 1) {
        const child = children[index];

        if (!child) {
            continue;
        }

        if (child.type === "image") {
            consumeWidthAfterImage(child, children, index);
        }

        applyImageWidths(child);
    }
}

/** Lifts a leading `{width=N}` from the text node after an image onto the image, consuming the text. */
function consumeWidthAfterImage(image: Nodes, children: Nodes[], index: number): void {
    const next = children[index + 1];

    if (next?.type !== "text") {
        return;
    }

    const match = /^\{([^}]*)\}/.exec(next.value);

    if (!match) {
        return;
    }

    const width = widthFromAttributes(match[1] ?? "");

    if (width === null) {
        return;
    }

    image.data = { ...image.data, width };
    const rest = next.value.slice(match[0].length);

    if (rest === "") {
        children.splice(index + 1, 1);
    } else {
        next.value = rest;
    }
}

/** Extracts a positive integer `width` from an attribute-list body, or null when absent/invalid. */
export function widthFromAttributes(attributes: string): number | null {
    const match = /(?:^|\s)width=(\d+)\b/.exec(attributes);

    if (!match) {
        return null;
    }

    const width = Number(match[1]);

    return width > 0 ? width : null;
}

/** Parses a non-negative integer width attribute value, or null when absent/invalid. */
function widthFromAttribute(value: string | null): number | null {
    if (value === null || !/^\d+$/.test(value)) {
        return null;
    }

    const width = Number(value);

    return width > 0 ? width : null;
}

/** Whether an editor inline node is an image. */
function isImage(node: InlineNode): node is InlineNode & { data: unknown } {
    return node.type === "custom" && node.extension === "image";
}

// Parse: an mdast image -> a custom image inline.

/** Converts an mdast image to a custom image inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent, _ctx: ParseContext): InlineNode | null {
    if (node.type !== "image") {
        return null;
    }

    const width = (node.data as ImageWidthData | undefined)?.width ?? null;

    return {
        data: { alt: node.alt ?? "", src: node.url, title: node.title ?? null, width },
        extension: "image",
        type: "custom",
    };
}

// Serialise-in: an <img> element -> a custom image inline.

/** Builds a custom image inline node from an `<img>` element. */
function imageInlineFromElement(element: Element): InlineNode {
    return {
        data: {
            alt: element.getAttribute("alt") ?? "",
            src: element.getAttribute("src") ?? "",
            title: element.getAttribute("title"),
            width: widthFromAttribute(element.getAttribute("width")),
        },
        extension: "image",
        type: "custom",
    };
}

/**
 * Whether an `<img>` is real content rather than an editor artifact. A meaningful image always carries a
 * `src`; a src-less `<img>` is a ProseMirror artifact -- its cursor-placement separator
 * (`class="ProseMirror-separator"`) beside an inline atom, or a leftover after an image is deleted -- and
 * must never serialise (otherwise a stray `![]()` is emitted).
 */
function isContentImage(element: Element): boolean {
    const src = element.getAttribute("src");

    return src !== null && src !== "";
}

/** Recognises a content `<img>` element and rebuilds the custom image inline, declining otherwise. */
function inlineFromElement(node: ChildNode): InlineNode[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (element.tagName !== "IMG") {
        return null;
    }

    return isContentImage(element) ? [imageInlineFromElement(element)] : [];
}

/**
 * Claims a block-level content `<img>` (the visual editor can render a standalone `![](url)` as a bare
 * top-level image rather than inside a paragraph) as a paragraph holding the image, declining otherwise.
 * A src-less artifact `<img>` is declined so the base extension drops it rather than emitting `![]()`.
 */
function blockFromElement(element: Element, _ctx: FromElementContext): EditorBlock | null {
    if (element.tagName !== "IMG" || !isContentImage(element)) {
        return null;
    }

    return {
        children: [imageInlineFromElement(element)],
        type: "paragraph",
    };
}

// Serialise-out: an image -> its `![alt](src "title")` form.

/** Serialises an image to its Markdown image form, declining any other inline node. */
function inlineToMarkdown(node: InlineNode, _ctx: ToMarkdownContext): string | null {
    if (!isImage(node)) {
        return null;
    }

    const { alt, src, title, width } = node.data as ImageData;
    const destination = title !== null ? `${src} "${title}"` : src;
    const widthSuffix = width !== null ? `{width=${width}}` : "";

    return `![${alt}](${destination})${widthSuffix}`;
}

/** GFM images (`![alt](src "title")`, optionally `{width=N}`) rendered inline as `<img>`; no raw HTML. */
export const imageExtension: ContentExtension = {
    blockFromElement,
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "image",
    remarkPlugins: [remarkImageWidth],
};
