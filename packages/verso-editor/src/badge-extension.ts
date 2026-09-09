import type { Nodes, PhrasingContent, Root } from "mdast";
import type { Plugin } from "unified";
import { BADGE_ATTR } from "./badge-syntax.js";
import type { ContentExtensionFor, ExtensionInlineInput } from "./content-extension.js";

// Badge lozenges (RFC-0021), an opt-in tree-mode content extension. The corpus writes a badge as an inline
// code span immediately followed by a `{.badge.<colour>}` attribute list (e.g. `` `TODO`{.badge.yellow} ``),
// which MkDocs renders as a coloured pill. The editor recognises exactly that shape, renders it as a pill,
// and round-trips it verbatim; every other attribute-list shape is left as literal text.

/** The payload on a custom badge inline node: the literal text and its colour class. */
interface BadgeData {
    text: string;
    colour: string;
}

declare module "./editor-model.js" {
    interface ContentExtensionPayloads {
        badge: { inline: BadgeData };
    }
}

// Parse: a remark transform fuses an `inlineCode` node and an immediately-following `{.badge.<colour>}`
// text node into a custom `badge` mdast node; inlineFromMdast then converts it to the editor model.

/** Fuses inline-code + badge-attribute pairs in a node's children into custom badge nodes, recursing. */
function fuseBadges(node: Nodes): void {
    if (!("children" in node)) {
        return;
    }

    const children = node.children as Nodes[];

    for (let index = 0; index < children.length; index += 1) {
        const code = children[index];
        const next = children[index + 1];

        if (code?.type === "inlineCode" && next?.type === "text") {
            const match = BADGE_ATTR.exec(next.value);

            if (match) {
                children[index] = { colour: match[1] ?? "", type: "badge", value: code.value } as unknown as Nodes;
                const rest = next.value.slice(match[0].length);

                if (rest === "") {
                    children.splice(index + 1, 1);
                } else {
                    next.value = rest;
                }
            }
        }
    }

    for (const child of children) {
        fuseBadges(child);
    }
}

/** The remark plugin that recognises badge lozenges before the model is built. */
const remarkBadges: Plugin<[], Root> = () => {
    return (tree: Root): void => {
        fuseBadges(tree as Nodes);
    };
};

/** Converts a fused `badge` mdast node to a custom badge inline node, declining any other node. */
function inlineFromMdast(node: PhrasingContent): ExtensionInlineInput<"badge"> | null {
    const badge = node as unknown as { type: string; value?: string; colour?: string };

    if (badge.type !== "badge") {
        return null;
    }

    return { data: { colour: badge.colour ?? "", text: badge.value ?? "" } };
}

// Serialise-in: a `span.badge` placeholder becomes a badge node, reading the colour from data-badge-colour
// and the literal text from the element's text content.

/** Recognises a rendered badge span and rebuilds the badge inline, declining otherwise. */
function inlineFromElement(node: ChildNode): ExtensionInlineInput<"badge">[] | null {
    if (node.nodeType !== Node.ELEMENT_NODE) {
        return null;
    }

    const element = node as Element;

    if (element.tagName !== "SPAN" || !element.classList.contains("badge")) {
        return null;
    }

    return [
        {
            data: { colour: element.getAttribute("data-badge-colour") ?? "", text: element.textContent ?? "" },
        },
    ];
}

// Serialise-out: the canonical `` `text`{.badge.<colour>} `` form, widening the backtick fence when the
// text itself contains backticks (CommonMark inline code).

/** Serialises a badge to its canonical Markdown, declining any other inline node. */
function inlineToMarkdown(data: BadgeData): string {
    const { text, colour } = data;

    return `${codeSpan(text)}{.badge.${colour}}`;
}

/** Wraps text as an inline code span, choosing a backtick fence long enough to contain any backticks. */
function codeSpan(text: string): string {
    const runs = text.match(/`+/g);
    const fence = "`".repeat((runs ? Math.max(...runs.map((run: string): number => run.length)) : 0) + 1);
    const pad = text.startsWith("`") || text.endsWith("`") ? " " : "";

    return `${fence}${pad}${text}${pad}${fence}`;
}

/** Badge lozenges (`` `text`{.badge.<colour>} ``); registered only in the trusted document-tree mode. */
export const badgeExtension: ContentExtensionFor<"badge"> = {
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "badge",
    remarkPlugins: [remarkBadges],
};
