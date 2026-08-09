/**
 * The Moebius watercolour background layers for markdown-editor.css.
 *
 * Numbers come verbatim from the approved prototype
 * (docs/mockups/markdown-editor-moebius-watercolour-prototype.html, variant D at its baked
 * defaults). The prototype remains the tuning surface: change a number there, read it off,
 * bring it here, then re-run `bun scripts/moebius/port.ts`.
 */

export type Scheme = "light" | "dark";
export type Direction = "h" | "v";

/**
 * Percent-encode the characters that cannot travel raw in a `url("data:image/svg+xml,...")`.
 *
 * This runs ONCE, here, over the whole SVG. Pre-encoding a colour before handing it to one of
 * the generators below yields `%2523`, which is not a colour, and SVG silently falls back to
 * black. That mistake is what made the dithered band read as the retired speckle.
 */
function enc(svg: string): string {
    const map: Record<string, string> = { "<": "%3C", ">": "%3E", "#": "%23", "%": "%25", '"': "%22" };
    let out = "";
    for (const ch of svg) {
        out += map[ch] ?? ch;
    }
    return out;
}

function url(svg: string): string {
    return `url("data:image/svg+xml,${enc(svg)}")`;
}

function svgOpen(w: number, h: number, stretch: boolean): string {
    const par = stretch ? " preserveAspectRatio='none'" : "";
    return `<svg xmlns='http://www.w3.org/2000/svg' width='${w}' height='${h}'${par}>`;
}

/** A: the wash mottling -- broad, soft, isotropic blotches, stretched to the element. */
export function mottle(colour: string, opacity: string, freq: string, seed: number, w: number, h: number): string {
    const svg =
        `${svgOpen(w, h, true)}<defs><filter id='m' x='0' y='0' width='100%' height='100%'>` +
        `<feTurbulence type='fractalNoise' baseFrequency='${freq}' numOctaves='3' seed='${seed}'/>` +
        "<feColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 2.4 -0.85'/>" +
        "<feComponentTransfer result='t'><feFuncA type='gamma' amplitude='1' exponent='1.5' offset='0'/></feComponentTransfer>" +
        `<feFlood flood-color='${colour}'/>` +
        "<feComposite in2='t' operator='in'/>" +
        "</filter></defs>" +
        `<rect width='100%' height='100%' filter='url(#m)' opacity='${opacity}'/>` +
        "</svg>";
    return `${url(svg)} center / 100% 100% no-repeat`;
}

/** B: bordered flecks -- small ink-rimmed specks, tiled rather than stretched. */
export function fleck(fill: string, ink: string, opacity: string, seed: number, tile = 340): string {
    const svg =
        `${svgOpen(tile, tile, false)}<defs><filter id='f' x='0' y='0' width='100%' height='100%'>` +
        `<feTurbulence type='fractalNoise' baseFrequency='0.045' numOctaves='3' seed='${seed}' stitchTiles='stitch'/>` +
        "<feColorMatrix values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 44 -35' result='t'/>" +
        "<feMorphology in='t' operator='dilate' radius='1.1' result='td'/>" +
        `<feFlood flood-color='${ink}'/>` +
        "<feComposite in2='td' operator='in' result='rim'/>" +
        `<feFlood flood-color='${fill}'/>` +
        "<feComposite in2='t' operator='in' result='core'/>" +
        "<feMerge><feMergeNode in='rim'/><feMergeNode in='core'/></feMerge>" +
        "</filter></defs>" +
        `<rect width='100%' height='100%' filter='url(#f)' opacity='${opacity}'/>` +
        "</svg>";
    return `${url(svg)} left top / ${tile}px ${tile}px repeat`;
}

/** C: the dithered transition band -- a stipple that states the fade's changeover early. */
export function dither(
    warm: string,
    opacity: string,
    seed: number,
    direction: Direction,
    w: number,
    h: number,
): string {
    const coords = direction === "h" ? "x1='0' y1='0' x2='1' y2='0'" : "x1='0' y1='0' x2='0' y2='1'";
    const svg =
        `${svgOpen(w, h, true)}<defs>` +
        `<linearGradient id='dg' ${coords}>` +
        "<stop offset='0' stop-color='black'/>" +
        "<stop offset='0.45' stop-color='#555555'/>" +
        "<stop offset='1' stop-color='white'/>" +
        "</linearGradient>" +
        "<filter id='d' x='0' y='0' width='100%' height='100%'>" +
        "<feColorMatrix in='SourceGraphic' type='luminanceToAlpha' result='ramp'/>" +
        `<feTurbulence type='fractalNoise' baseFrequency='2' numOctaves='2' seed='${seed}' result='n'/>` +
        "<feColorMatrix in='n' values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0' result='na'/>" +
        "<feComposite in='ramp' in2='na' operator='arithmetic' k1='0' k2='0.8' k3='0.75' k4='0' result='sum'/>" +
        "<feColorMatrix in='sum' values='0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 16 -10.4' result='cut'/>" +
        `<feFlood flood-color='${warm}'/>` +
        "<feComposite in2='cut' operator='in'/>" +
        "</filter></defs>" +
        `<rect width='100%' height='100%' fill='url(#dg)' filter='url(#d)' opacity='${opacity}'/>` +
        "</svg>";
    return `${url(svg)} center / 100% 100% no-repeat`;
}

/**
 * E: the hatched shadow bank.
 *
 * Tiled along the run at 240px rather than stretched: a hatch is directional, so stretching it
 * to a panel of unknown width would swing its angle and fatten its strokes (isotropic noise
 * merely goes elliptical, which is why the mottling can stretch and this cannot). 240 is the
 * seam-safe width: the lines have perpendicular spacing 4 at 28 degrees from vertical, so they
 * repeat along x every 4/cos(28) = 4.5303px, and 240 is 52.98 of those -- a 0.09px step at the
 * tile join. Only the height stretches, and these bars keep a near-fixed height.
 */
export function hatch(
    colour: string,
    opacity: string,
    seed: number,
    band: readonly [string, string],
    h: number,
    w = 240,
): string {
    const svg =
        `${svgOpen(w, h, true)}<defs>` +
        "<pattern id='tp' width='4' height='4' patternUnits='userSpaceOnUse' patternTransform='rotate(-28)'>" +
        `<line x1='1' y1='0' x2='1' y2='4' stroke='${colour}' stroke-width='1.1'/>` +
        "</pattern>" +
        "<linearGradient id='tg' x1='0' y1='0' x2='0' y2='1'>" +
        `<stop offset='${band[0]}' stop-color='white' stop-opacity='0'/>` +
        `<stop offset='${band[1]}' stop-color='white' stop-opacity='0.3'/>` +
        "<stop offset='1' stop-color='white' stop-opacity='1'/>" +
        "</linearGradient>" +
        "<mask id='tm'><rect width='100%' height='100%' fill='url(#tg)'/></mask>" +
        "<filter id='tf' x='-5%' y='-5%' width='110%' height='110%'>" +
        `<feTurbulence type='fractalNoise' baseFrequency='0.06' numOctaves='2' seed='${seed}' stitchTiles='stitch' result='n'/>` +
        "<feDisplacementMap in='SourceGraphic' in2='n' scale='2.5'/>" +
        "</filter></defs>" +
        `<g mask='url(#tm)' opacity='${opacity}'>` +
        "<rect width='100%' height='100%' fill='url(#tp)' filter='url(#tf)'/>" +
        "</g></svg>";
    return `${url(svg)} left bottom / ${w}px 100% repeat-x`;
}

interface Tint {
    shade: string;
    lift: string;
    fleckFill: string;
    fleckInk: string;
    hatch: string;
}

interface Opacities {
    mottle: string;
    lift: string;
    fleck: string;
    dither: string;
    hatch: string;
}

/** The approved palette. */
export const TINT: Record<Scheme, Tint> = {
    light: { shade: "#7a5c3e", lift: "#fffdf2", fleckFill: "#e9d3a8", fleckInk: "#4a3428", hatch: "#4a3428" },
    dark: { shade: "#05061c", lift: "#aeb6e8", fleckFill: "#313877", fleckInk: "#05061c", hatch: "#05061c" },
};

/** The approved strengths. */
export const OP: Record<Scheme, Opacities> = {
    light: { mottle: "0.036", lift: "0.032", fleck: "0.75", dither: "0.19", hatch: "0.68" },
    dark: { mottle: "0.032", lift: "0.026", fleck: "0.88", dither: "0.4", hatch: "0.98" },
};

export interface Panel {
    /** Authored width. NOT the element's -- see the note on PANELS. */
    w: number;
    /** Authored height. NOT the element's -- see the note on PANELS. */
    h: number;
    dirn: Direction;
    /** Seeds for the shade mottle, the lift mottle and the dither, in that order. */
    seeds: readonly [number, number, number];
    /** False on surfaces whose own bands already carry the colour change. */
    dither?: boolean;
    /** Seed for the fleck layer; absent means the panel takes no flecks. */
    fleck?: number;
    /** Seed for the hatch layer; absent means the panel takes no shadow bank. */
    hatch?: number;
    /** Mask stops for the hatch, as fractions of the panel's height. */
    band?: readonly [string, string];
}

export type PanelName = "nav" | "topbar" | "content" | "toolbar";

/**
 * Author size is the PROTOTYPE's, not the element's.
 *
 * Every layer stretches to its element, so the on-screen grain is
 * `(1/frequency) x (element / authored)`: matching the authored size to the element removes the
 * stretch the prototype depends on and shrinks the texture -- by 1.75x on the rail, measured,
 * when that was tried.
 *
 * These are the prototype's numbers verbatim, and every surface is anchored to its own element
 * as the prototype anchors them, so the mapping matches as well as the scale.
 */
export const PANELS: Record<PanelName, Panel> = {
    // The rail takes no dithered transition. Its bands already carry the colour, so the stipple
    // had no changeover to state and was simply fine grain gathering at the foot -- which is the
    // retired speckle's effect, in the retired speckle's place.
    nav: { w: 220, h: 660, dirn: "v", seeds: [1, 5, 4], dither: false },
    topbar: { w: 980, h: 92, dirn: "h", seeds: [11, 15, 14], fleck: 13, hatch: 18, band: ["0.62", "0.82"] },
    content: { w: 780, h: 620, dirn: "v", seeds: [21, 25, 24] },
    toolbar: { w: 560, h: 46, dirn: "h", seeds: [31, 35, 34], fleck: 33, hatch: 38, band: ["0.50", "0.74"] },
};
