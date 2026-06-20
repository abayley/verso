import type { Nodes, PhrasingContent, Root } from "mdast";
import type { Plugin } from "unified";
import { BADGE_ATTR, badgeStyle, COLOUR_TOKEN } from "./badge-syntax.js";
import type { ContentExtension, RenderContext } from "./content-extension.js";
import type { InlineNode } from "./editor-model.js";

// Badge lozenges (RFC-0021), an opt-in tree-mode content extension. The corpus writes a badge as an inline
// code span immediately followed by a `{.badge.<colour>}` attribute list (e.g. `` `TODO`{.badge.yellow} ``),
// which MkDocs renders as a coloured pill. The editor recognises exactly that shape, renders it as a pill,
// and round-trips it verbatim; every other attribute-list shape is left as literal text.

/** The payload on a custom badge inline node: the literal text and its colour class. */
interface BadgeData {
    text: string;
    colour: string;
}

/** Whether an editor inline node is a badge. */
function isBadge(node: InlineNode): node is InlineNode & { data: BadgeData } {
    return node.type === "custom" && node.extension === "badge";
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
function inlineFromMdast(node: PhrasingContent): InlineNode | null {
    const badge = node as unknown as { type: string; value?: string; colour?: string };

    if (badge.type !== "badge") {
        return null;
    }

    return { data: { colour: badge.colour ?? "", text: badge.value ?? "" }, extension: "badge", type: "custom" };
}

// Render: a coloured pill. The colour sets the background inline (it is a validated colour token, so there
// is no CSS-injection surface); an unknown colour the browser rejects falls back to the neutral `.badge`
// pill. `data-badge-colour` is the source of truth the DOM serialise reads back.

/** Renders a badge to a `span.badge` pill, declining any other inline node. */
function renderInline(node: InlineNode, ctx: RenderContext): string | null {
    if (!isBadge(node)) {
        return null;
    }

    const { text, colour } = node.data;
    const style = COLOUR_TOKEN.test(colour) ? ` style="${ctx.escapeHtml(badgeStyle(colour))}"` : "";

    return `<span class="badge" data-badge-colour="${ctx.escapeHtml(colour)}"${style}>${ctx.escapeHtml(text)}</span>`;
}

// Serialise-in: a `span.badge` placeholder becomes a badge node, reading the colour from data-badge-colour
// and the literal text from the element's text content.

/** Recognises a rendered badge span and rebuilds the badge inline, declining otherwise. */
function inlineFromElement(node: ChildNode): InlineNode[] | null {
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
            extension: "badge",
            type: "custom",
        },
    ];
}

// Serialise-out: the canonical `` `text`{.badge.<colour>} `` form, widening the backtick fence when the
// text itself contains backticks (CommonMark inline code).

/** Serialises a badge to its canonical Markdown, declining any other inline node. */
function inlineToMarkdown(node: InlineNode): string | null {
    if (!isBadge(node)) {
        return null;
    }

    const { text, colour } = node.data;

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
export const badgeExtension: ContentExtension = {
    inlineFromElement,
    inlineFromMdast,
    inlineToMarkdown,
    name: "badge",
    remarkPlugins: [remarkBadges],
    renderInline,
};
