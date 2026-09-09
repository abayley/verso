/**
 * Lazy loader for the Mermaid diagram runtime (RFC-0033, ADR-0071). Mermaid is large, so it is built as a
 * separate bundle (`static/editor/mermaid.js`) and loaded on demand only when a page actually contains a
 * `mermaid` fence — never as part of the base editor bundle. This module lives in the main bundle and only
 * references the separate bundle by URL, so importing it does not pull Mermaid in.
 */

/** The window global the Mermaid bundle assigns its render API to. */
const MERMAID_GLOBAL = "__versoMermaid";

/** The URL the Mermaid bundle is served from (same origin; no external fetch). */
const MERMAID_SRC = "/static/editor/mermaid.js";

/** The outcome of a diagram render: either the SVG markup, or a parse/render error message. */
export interface MermaidRenderResult {
    svg?: string;
    error?: string;
}

/** The render API the Mermaid bundle exposes on the window global. */
export interface VersoMermaid {
    render(id: string, source: string, dark: boolean): Promise<MermaidRenderResult>;
}

interface MermaidWindow extends Window {
    [MERMAID_GLOBAL]?: VersoMermaid;
}

let loadPromise: Promise<VersoMermaid> | null = null;

/**
 * Resolves the Mermaid render API, loading the separate bundle on first call and reusing it thereafter. A
 * failed load rejects and clears the cached promise so a later attempt can retry.
 */
export function loadMermaid(): Promise<VersoMermaid> {
    const win = window as MermaidWindow;
    const existing = win[MERMAID_GLOBAL];

    if (existing) {
        return Promise.resolve(existing);
    }

    if (loadPromise) {
        return loadPromise;
    }

    loadPromise = new Promise<VersoMermaid>((resolve, reject) => {
        const script = document.createElement("script");
        script.src = MERMAID_SRC;
        script.addEventListener("load", (): void => {
            const api = (window as MermaidWindow)[MERMAID_GLOBAL];

            if (api) {
                resolve(api);
            } else {
                loadPromise = null;
                reject(new Error("Mermaid bundle loaded but exposed no render API"));
            }
        });
        script.addEventListener("error", (): void => {
            loadPromise = null;
            script.remove();
            reject(new Error("Failed to load the Mermaid bundle"));
        });
        document.head.append(script);
    });

    return loadPromise;
}

/** The window global name the Mermaid bundle must assign to; shared with the bundle entry point. */
export const MERMAID_GLOBAL_NAME = MERMAID_GLOBAL;
