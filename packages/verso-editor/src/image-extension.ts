import type { Nodes, PhrasingContent, Root } from "mdast";
import type { Plugin } from "unified";
import type { ContentExtensionFor, ExtensionInlineInput, ParseContext } from "./content-extension.js";

/** The payload on a custom image inline node. */
interface ImageData {
    alt: string;
    src: string;
    title: string | null;
    /** Display width in pixels from a `{width=N}` attribute, or null when unsized. */
    width: number | null;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        image: { inline: ImageData };
    }
}

/** A width attached to an mdast image node by the attribute-parsing transform. */
interface ImageWidthData {
    width?: number;
}

/**
 * Parses a Pandoc-style attribute list (`{width=N}`) that immediately follows an image and attaches the
 * width to the image node. Markdown has no native image-size syntax and the project rejects raw `<img>`
 * HTML (ADR-0040/0041), so the size travels as a documented Markdown attribute list. remark parses the
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

// Parse: an mdast image -> a custom image inline.

/** Converts an mdast image to a custom image inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent, _ctx: ParseContext): ExtensionInlineInput<"image"> | null {
    if (node.type !== "image") {
        return null;
    }

    const width = (node.data as ImageWidthData | undefined)?.width ?? null;

    return {
        data: { alt: node.alt ?? "", src: node.url, title: node.title ?? null, width },
    };
}

// Serialise-in: an <img> element -> a custom image inline.

/** Builds a custom image inline node from an `<img>` element. */
function imageInlineFromElement(element: Element): ExtensionInlineInput<"image"> {
    return {
        data: {
            alt: element.getAttribute("alt") ?? "",
            src: element.getAttribute("src") ?? "",
            title: element.getAttribute("title"),
            width: widthFromAttribute(element.getAttribute("width")),
        },
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
function inlineFromElement(node: ChildNode): ExtensionInlineInput<"image">[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (element.tagName !== "IMG") {
        return null;
    }

    return isContentImage(element) ? [imageInlineFromElement(element)] : [];
}

// Serialise-out: an image -> its `![alt](src "title")` form.

/** Serialises an image to its Markdown image form, declining any other inline node. */
function inlineToMarkdown(data: ImageData): string {
    const { alt, src, title, width } = data;
    const destination = title !== null ? `${src} "${title}"` : src;
    const widthSuffix = width !== null ? `{width=${width}}` : "";

    return `![${alt}](${destination})${widthSuffix}`;
}

/** GFM images (`![alt](src "title")`, optionally `{width=N}`) rendered inline as `<img>`; no raw HTML. */
export const imageExtension: ContentExtensionFor<"image"> = {
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "image",
    remarkPlugins: [remarkImageWidth],
};
