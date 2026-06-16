import "./base-extension.js";

/**
 * The DOM-to-model and model-to-Markdown serialisers run through the content-extension registry.
 * This module re-exports the registry entry points and ensures the base extension is registered.
 */
export { documentFromElements, documentToMarkdown } from "./content-extension.js";
