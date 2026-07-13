import { ensureSyntaxTree } from "@codemirror/language";
import type { EditorState, Extension } from "@codemirror/state";
import { RangeSetBuilder, StateField } from "@codemirror/state";
import type { DecorationSet } from "@codemirror/view";
import { Decoration, EditorView } from "@codemirror/view";
import { fenceLowlight } from "./fence-grammars.js";

/** The lowlight (hast) node shapes consumed by the decoration walk. */
interface HastText {
    type: "text";
    value: string;
}

interface HastElement {
    type: "element";
    properties?: { className?: readonly string[] };
    children: readonly HastNode[];
}

type HastNode = HastText | HastElement | { type: string };

/** How long the Markdown parser may run per recompute before unparsed fences are skipped. */
const PARSE_BUDGET_MILLISECONDS = 50;

/**
 * Highlights fenced code-block bodies in the Markdown source view with the same curated highlight.js
 * grammars (via lowlight) the visual editor uses, emitting `hljs-*` mark decorations so the RFC-0033
 * palette CSS colours both modes identically. Fences with an unregistered language are left undecorated.
 */
export function fenceHighlighting(): Extension {
    const field = StateField.define<DecorationSet>({
        create: fenceDecorations,
        update: (decorations, transaction) =>
            transaction.docChanged ? fenceDecorations(transaction.state) : decorations,
        provide: (self) => EditorView.decorations.from(self),
    });

    return field;
}

/** Builds hljs mark decorations for every registered-language fence in the document. */
function fenceDecorations(state: EditorState): DecorationSet {
    const builder = new RangeSetBuilder<Decoration>();
    const tree = ensureSyntaxTree(state, state.doc.length, PARSE_BUDGET_MILLISECONDS);

    tree?.iterate({
        enter: (node): void => {
            if (node.name !== "FencedCode") {
                return;
            }

            const info = node.node.getChild("CodeInfo");
            const text = node.node.getChild("CodeText");
            const language = info ? state.doc.sliceString(info.from, info.to).trim().split(/\s+/)[0] : undefined;

            if (!text || !language || !fenceLowlight.registered(language)) {
                return;
            }

            // The base mark resets the palette's blue literal colour across the whole fence body, so
            // unclassed code text reads as plain text; the hljs token marks nest inside it.
            builder.add(text.from, text.to, Decoration.mark({ class: "markdown-editor__fence-code" }));
            const highlighted = fenceLowlight.highlight(language, state.doc.sliceString(text.from, text.to));
            emitMarks(highlighted.children as readonly HastNode[], text.from, [], builder);
        },
    });

    return builder.finish();
}

/**
 * Walks a lowlight hast fragment in document order, emitting one mark per text run that sits inside at
 * least one classed element. Returns the document offset just past the fragment.
 */
function emitMarks(
    nodes: readonly HastNode[],
    offset: number,
    classes: readonly string[],
    builder: RangeSetBuilder<Decoration>,
): number {
    let position = offset;

    for (const node of nodes) {
        if (node.type === "text") {
            const { value } = node as HastText;

            if (classes.length > 0) {
                builder.add(position, position + value.length, Decoration.mark({ class: classes.join(" ") }));
            }

            position += value.length;
        } else if (node.type === "element") {
            const element = node as HastElement;
            const elementClasses = element.properties?.className ?? [];
            position = emitMarks(element.children, position, [...classes, ...elementClasses], builder);
        }
    }

    return position;
}
