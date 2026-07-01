import mermaid from "mermaid";
import { MERMAID_GLOBAL_NAME, type MermaidRenderResult, type VersoMermaid } from "./mermaid-loader.js";

/**
 * The Mermaid bundle entry point (RFC-0033, ADR-071). Built as a separate `static/editor/mermaid.js` bundle
 * and loaded on demand by {@link ./mermaid-loader}; it imports the large Mermaid runtime (kept out of the
 * base editor bundle) and exposes a small render API on the window global. Mermaid runs at
 * `securityLevel: "strict"` (its bundled DOMPurify sanitises output; no eval/inline handlers).
 */
const api: VersoMermaid = {
    async render(id: string, source: string, dark: boolean): Promise<MermaidRenderResult> {
        mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            theme: dark ? "dark" : "default",
        });

        try {
            const { svg } = await mermaid.render(id, source);

            return { svg };
        } catch (error) {
            return { error: error instanceof Error ? error.message : String(error) };
        }
    },
};

(window as unknown as Record<string, unknown>)[MERMAID_GLOBAL_NAME] = api;
