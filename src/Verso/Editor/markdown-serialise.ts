import type { EditorDocument } from "./editor-model.js";
import { commonContentPipeline } from "./register-extensions.js";

/** Converts rendered DOM through the temporary common compatibility pipeline. */
export function documentFromElements(elements: HTMLCollection | Element[]): EditorDocument {
    return commonContentPipeline.documentFromElements(elements);
}

/** Serialises an editor document through the temporary common compatibility pipeline. */
export function documentToMarkdown(document: EditorDocument): string {
    return commonContentPipeline.documentToMarkdown(document);
}
