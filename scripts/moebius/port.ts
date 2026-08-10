/**
 * Rebuild the Moebius watercolour backgrounds in static/editor/markdown-editor.css.
 *
 * Run it with `bun scripts/moebius/port.ts`; `--check` reports whether the file is already
 * what this script would write, and exits non-zero if it is not.
 *
 * The CSS this touches is a bake, not a source. Hand-edit it and the next run reverts the
 * edit silently -- that has already cost two rounds of re-finding the same symptom. The
 * numbers live in the prototype
 * (docs/mockups/markdown-editor-moebius-watercolour-prototype.html); the layer order,
 * authored sizes, attachments and encoding live here.
 *
 * Idempotent by design: every background is rebuilt from scratch rather than appended to, so
 * repeated runs cannot stack duplicate layers.
 */

import { readFileSync, writeFileSync } from "node:fs";
import process from "node:process";
import { build as buildFade, type SurfaceName } from "./fade.ts";
import { dither, fleck, hatch, mottle, OP, PANELS, type PanelName, type Scheme, TINT } from "./wash.ts";

const CSS = new URL("../../static/editor/markdown-editor.css", import.meta.url).pathname;

const FADE = buildFade();

/**
 * Split a `background` value on its top-level commas.
 *
 * A layer is full of nested parens and quoted data URIs, so a plain split on "," shreds it.
 */
function splitLayers(value: string): string[] {
    const out: string[] = [];
    let depth = 0;
    let quote: string | null = null;
    let buf = "";
    for (const ch of value) {
        if (quote !== null) {
            buf += ch;
            if (ch === quote) quote = null;
            continue;
        }
        if (ch === '"' || ch === "'") {
            quote = ch;
            buf += ch;
        } else if (ch === "(") {
            depth += 1;
            buf += ch;
        } else if (ch === ")") {
            depth -= 1;
            buf += ch;
        } else if (ch === "," && depth === 0) {
            out.push(buf.trim());
            buf = "";
        } else {
            buf += ch;
        }
    }
    out.push(buf.trim());
    return out;
}

interface Target {
    selector: string;
    panel: PanelName;
    /** The fade surface whose far colour the stipple states; null means no stipple. */
    fade: SurfaceName | null;
    scheme: Scheme;
    /** The opaque base the wash sits on -- the fade is folded into this token's gradient. */
    colour: string;
    /** Keep the existing hand-drawn edge layer, which this script does not generate. */
    keepDrawnEdge: boolean;
}

const TARGETS: readonly Target[] = [
    {
        selector: ':root[data-editor-theme="moebius"] .markdown-editor__nav',
        panel: "nav",
        fade: "rail",
        scheme: "light",
        colour: "var(--moebius-rail)",
        keepDrawnEdge: false,
    },
    {
        selector: ':root[data-editor-theme="moebius"].dark .markdown-editor__nav',
        panel: "nav",
        fade: "rail",
        scheme: "dark",
        colour: "var(--moebius-rail)",
        keepDrawnEdge: false,
    },
    {
        selector: ':root[data-editor-theme="moebius"] .markdown-editor__topbar',
        panel: "topbar",
        fade: "bar",
        scheme: "light",
        colour: "var(--moebius-bar-lo)",
        keepDrawnEdge: true,
    },
    {
        selector: ':root[data-editor-theme="moebius"].dark .markdown-editor__topbar',
        panel: "topbar",
        fade: "bar",
        scheme: "dark",
        colour: "var(--moebius-bar-lo)",
        keepDrawnEdge: true,
    },
    {
        selector: ':root[data-editor-theme="moebius"] .markdown-editor__content::before',
        panel: "content",
        fade: "page",
        scheme: "light",
        colour: "var(--moebius-page)",
        keepDrawnEdge: false,
    },
    {
        selector: ':root[data-editor-theme="moebius"].dark .markdown-editor__content::before',
        panel: "content",
        fade: "page",
        scheme: "dark",
        colour: "var(--moebius-page)",
        keepDrawnEdge: false,
    },
    {
        selector: ':root[data-editor-theme="moebius"] .markdown-editor__toolbar--commands',
        panel: "toolbar",
        fade: null,
        scheme: "light",
        colour: "var(--markdown-editor-pill-background)",
        keepDrawnEdge: false,
    },
    {
        selector: ':root[data-editor-theme="moebius"].dark .markdown-editor__toolbar--commands',
        panel: "toolbar",
        fade: null,
        scheme: "dark",
        colour: "var(--markdown-editor-pill-background)",
        keepDrawnEdge: false,
    },
];

/** How many layers each panel must end up with. A miscount means a layer was lost or doubled. */
const EXPECT: Record<PanelName, number> = { nav: 3, topbar: 7, content: 4, toolbar: 5 };

/** The wash without its fade gradients: those are folded into the base colour token now. */
function washLayers(panel: PanelName, scheme: Scheme, fade: SurfaceName | null): string[] {
    const t = TINT[scheme];
    const o = OP[scheme];
    const p = PANELS[panel];
    const [shadeSeed, liftSeed, ditherSeed] = p.seeds;
    const out = [
        mottle(t.shade, o.mottle, "0.00205", shadeSeed, p.w, p.h),
        mottle(t.lift, o.lift, "0.00275", liftSeed, p.w, p.h),
    ];
    if (p.fleck !== undefined) {
        out.push(fleck(t.fleckFill, t.fleckInk, o.fleck, p.fleck));
    }
    if (fade !== null && p.dither !== false) {
        // The stipple keeps the transition, drawn in the colour the fade reaches at the far end
        // so it states the change early without lifting anything.
        //
        // Pass the colour RAW. wash.ts percent-encodes the whole SVG, so a "#" pre-encoded here
        // becomes "%2523" -- not a colour at all, and SVG then falls back to black. That is what
        // made the stipple read as the retired speckle: black dots, in the speckle's old place,
        // at the speckle's old strength.
        const far = FADE[fade][scheme].dither;
        out.push(dither(far, o.dither, ditherSeed, p.dirn, p.w, p.h));
    }
    if (p.hatch !== undefined) {
        if (p.band === undefined) throw new Error(`panel ${panel} has a hatch seed but no band`);
        out.push(hatch(t.hatch, o.hatch, p.hatch, p.band, p.h));
    }
    return out;
}

const BACKGROUND = /\n {2}background: (.*?);(?=\n|$)/s;
const ORIGIN = /\n {2}background-origin: (.*?);(?=\n|$)/s;

function ruleSpan(css: string, selector: string): { start: number; end: number } {
    const start = css.indexOf(`${selector} {`);
    if (start < 0) throw new Error(`selector not found: ${selector}`);
    const end = css.indexOf("\n}\n", start);
    if (end < 0) throw new Error(`unterminated rule: ${selector}`);
    return { start, end };
}

/** The hand-drawn border layer, identified by the one thing only it carries. */
function drawnEdge(css: string, selector: string): string {
    const { start, end } = ruleSpan(css, selector);
    const match = BACKGROUND.exec(css.slice(start, end));
    if (match?.[1] === undefined) throw new Error(`no background in ${selector}`);
    for (const layer of splitLayers(match[1])) {
        if (layer.includes("stroke-linecap")) return layer;
    }
    throw new Error(`no drawn edge in ${selector}`);
}

/**
 * The theme's base-colour tokens, each carrying the hue fade already folded in.
 *
 * Nothing translucent sits on top of these, so nothing has to be blended. The night values
 * come out at constant luminance -- the tint contributes hue and saturation while the surface
 * keeps its own depth -- which is why a night fade cannot simply interpolate toward its tint:
 * #3d2a5c carries 4.1x the luminance of #12142f, so a plain fade to it bleaches the panel.
 */
const TOKENS: ReadonlyArray<{ token: string; surface: SurfaceName }> = [
    { token: "--moebius-bar-hi", surface: "barhi" },
    { token: "--moebius-bar-lo", surface: "bar" },
    { token: "--moebius-page", surface: "page" },
    { token: "--moebius-rail", surface: "rail" },
];

/** The two blocks that declare the tokens: the theme's own, and its dark override. */
const TOKEN_BLOCKS: ReadonlyArray<{ selector: string; scheme: Scheme }> = [
    { selector: ':root[data-editor-theme="moebius"]', scheme: "light" },
    { selector: ':root[data-editor-theme="moebius"].dark', scheme: "dark" },
];

function rebuildTokens(css: string): string {
    let s = css;
    for (const block of TOKEN_BLOCKS) {
        const { start, end } = ruleSpan(s, block.selector);
        let body = s.slice(start, end);
        for (const { token, surface } of TOKENS) {
            const declaration = new RegExp(`\\n {2}${token}: [^;]+;`);
            const match = declaration.exec(body);
            if (match === null) throw new Error(`${block.selector}: no ${token} declaration`);
            body = body.replace(declaration, `\n  ${token}: ${FADE[surface][block.scheme].gradient};`);
        }
        s = s.slice(0, start) + body + s.slice(end);
    }
    return s;
}

function rebuild(css: string): string {
    let s = rebuildTokens(css);
    for (const target of TARGETS) {
        const head = target.keepDrawnEdge ? [drawnEdge(s, target.selector)] : [];
        // No layer carries `background-attachment: fixed`. The content wash is pinned to the
        // viewport by painting it on a fixed-position backdrop instead; attachment gives the
        // same picture at roughly 350x the raster cost, because a fixed background cannot ride
        // the scrolling layer and so re-runs its feTurbulence every frame. The measurements are
        // in the CSS comment above that rule, and in
        // docs/design/drawn-frames-paint-profile.md.
        const layers = [...head, ...washLayers(target.panel, target.scheme, target.fade), target.colour];
        const expected = EXPECT[target.panel];
        if (layers.length !== expected) {
            throw new Error(`${target.selector}: built ${layers.length} layers, expected ${expected}`);
        }

        const { start, end } = ruleSpan(s, target.selector);
        let body = s.slice(start, end);

        const bg = BACKGROUND.exec(body);
        if (bg === null) throw new Error(`no background in ${target.selector}`);
        body =
            body.slice(0, bg.index) +
            `\n  background: ${layers.join(",\n    ")};` +
            body.slice(bg.index + bg[0].length);

        const origin = ORIGIN.exec(body);
        if (origin?.[1] !== undefined && new Set(origin[1].split(",").map((v) => v.trim())).size > 1) {
            const values = ["border-box", ...Array<string>(layers.length - 1).fill("padding-box")];
            body =
                body.slice(0, origin.index) +
                `\n  background-origin: ${values.join(", ")};` +
                body.slice(origin.index + origin[0].length);
        }

        // The blend modes go with the overlays they existed to tame.
        body = body.replace(/\n {2}background-blend-mode: [^;]+;/g, "");
        s = s.slice(0, start) + body + s.slice(end);
    }
    return s;
}

const current = readFileSync(CSS, "utf8");
const next = rebuild(current);
const check = process.argv.includes("--check");

if (check) {
    if (next === current) {
        console.log("markdown-editor.css matches the generated Moebius wash");
    } else {
        console.error("markdown-editor.css differs from the generated Moebius wash; run bun scripts/moebius/port.ts");
        process.exit(1);
    }
} else if (next === current) {
    console.log("markdown-editor.css already up to date");
} else {
    writeFileSync(CSS, next);
    console.log("markdown-editor.css rewritten");
}
