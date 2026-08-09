/**
 * Bake the prototype's plain-gradient hue fade into literal CSS gradients.
 *
 * Mirrors fadedColour/fadedBase in
 * docs/mockups/markdown-editor-moebius-watercolour-prototype.html at the settled defaults:
 * strength at centre, which means a full hue shift with the luminance held (travel = 0). The
 * prototype is the tuning surface; this is the bake.
 */

import type { Direction, Scheme } from "./wash.ts";

type Rgb = readonly [number, number, number];

/**
 * Round half to even.
 *
 * This exists to match Python's `round`, which the original generator used. Ordinary
 * half-up rounding differs on exact .5 and would shift the odd baked channel by one, which
 * is enough to break a byte-for-byte comparison against the committed CSS.
 */
function roundHalfEven(v: number): number {
    const floor = Math.floor(v);
    const frac = v - floor;
    if (frac > 0.5) return floor + 1;
    if (frac < 0.5) return floor;
    return floor % 2 === 0 ? floor : floor + 1;
}

function srgbToLin(c: number): number {
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

function linToSrgb(c: number): number {
    const x = Math.max(0, Math.min(1, c));
    return x <= 0.0031308 ? x * 12.92 : 1.055 * x ** (1 / 2.4) - 0.055;
}

function hexToRgb(hex: string): Rgb {
    const h = hex.replace(/^#/, "");
    const at = (i: number): number => Number.parseInt(h.slice(i, i + 2), 16);
    return [at(0), at(2), at(4)];
}

function rgbToHex(rgb: Rgb): string {
    const channel = (v: number): string =>
        Math.max(0, Math.min(255, roundHalfEven(v)))
            .toString(16)
            .padStart(2, "0");
    return `#${channel(rgb[0])}${channel(rgb[1])}${channel(rgb[2])}`;
}

function luminance(rgb: Rgb): number {
    return 0.2126 * srgbToLin(rgb[0] / 255) + 0.7152 * srgbToLin(rgb[1] / 255) + 0.0722 * srgbToLin(rgb[2] / 255);
}

/** The tint carried at `lift` times the surface's own luminance. */
function atLuminance(tintHex: string, baseRgb: Rgb, lift: number): Rgb {
    const tint = hexToRgb(tintHex);
    const lt = luminance(tint);
    if (lt <= 0) return baseRgb;
    const k = (luminance(baseRgb) * lift) / lt;
    const carry = (v: number): number => linToSrgb(srgbToLin(v / 255) * k) * 255;
    return [carry(tint[0]), carry(tint[1]), carry(tint[2])];
}

function mix(a: Rgb, b: Rgb, t: number): Rgb {
    return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

function coolAt(p: number): number {
    return Math.max(0, 1 - p / 0.48);
}

function warmAt(p: number): number {
    return Math.max(0, (p - 0.52) / 0.48);
}

const TINT: Record<Scheme, { cool: string; warm: string }> = {
    light: { cool: "#9fc6bf", warm: "#cf9668" },
    dark: { cool: "#6f9fd0", warm: "#3d2a5c" },
};

/**
 * Alphas at the settled default. Night runs its hue to the full tint; day keeps the softer
 * alphas, because there the tint itself is the whole effect.
 */
const ALPHA: Record<Scheme, { cool: number; warm: number }> = {
    light: { cool: 0.4, warm: 0.45 },
    dark: { cool: 1.0, warm: 1.0 },
};

/** travel = 0 at the default, so the night lift is 1: luminance exactly held. */
const TRAVEL_LIFT = 1.0;

function fadedColour(baseHex: string, p: number, scheme: Scheme, weight: number): string {
    let rgb = hexToRgb(baseHex);
    const ends = [
        { end: "cool", ramp: coolAt },
        { end: "warm", ramp: warmAt },
    ] as const;
    for (const { end, ramp } of ends) {
        const alpha = Math.min(1, ALPHA[scheme][end]) * weight * ramp(p);
        if (alpha <= 0) continue;
        const tint = TINT[scheme][end];
        const target = scheme === "dark" ? atLuminance(tint, rgb, TRAVEL_LIFT) : hexToRgb(tint);
        rgb = mix(rgb, target, Math.min(1, alpha));
    }
    return rgbToHex(rgb);
}

/** A band of the surface's own colour ramp: colour, start fraction, end fraction. */
type Band = readonly [string, number, number];

function fadedGradient(bands: readonly Band[], direction: Direction, scheme: Scheme, weight: number): string {
    const angle = direction === "h" ? "90deg" : "180deg";
    const first = bands[0];
    if (first === undefined) throw new Error("a surface needs at least one band");
    if (bands.length === 1) {
        const stops = [0, 0.24, 0.5, 0.76, 1].map(
            (p) => `${fadedColour(first[0], p, scheme, weight)} ${roundHalfEven(p * 100)}%`,
        );
        return `linear-gradient(${angle}, ${stops.join(", ")})`;
    }
    const parts = bands.map(([colour, a, b]) => {
        const c = fadedColour(colour, (a + b) / 2, scheme, weight);
        return `${c} ${roundHalfEven(a * 100)}% ${roundHalfEven(b * 100)}%`;
    });
    return `linear-gradient(${angle}, ${parts.join(", ")})`;
}

/** The colour the fade reaches at the far end -- what the stipple states early. */
function ditherColour(bands: readonly Band[], scheme: Scheme, weight: number): string {
    const last = bands[bands.length - 1];
    if (last === undefined) throw new Error("a surface needs at least one band");
    return fadedColour(last[0], 1.0, scheme, weight);
}

export type SurfaceName = "rail" | "barhi" | "bar" | "page";

interface Surface {
    dir: Direction;
    weight: number;
    bands: Record<Scheme, readonly Band[]>;
}

const SURFACES: Record<SurfaceName, Surface> = {
    rail: {
        dir: "v",
        weight: 1.0,
        bands: {
            light: [
                ["#cfe7e2", 0, 0.12],
                ["#dde8d2", 0.12, 0.24],
                ["#f7efdd", 0.24, 0.62],
                ["#e9d3a8", 0.62, 0.84],
                ["#d9b57e", 0.84, 1],
            ],
            dark: [
                ["#131637", 0, 0.3],
                ["#1b2049", 0.3, 0.62],
                ["#232963", 0.62, 1],
            ],
        },
    },
    barhi: {
        dir: "h",
        weight: 0.4,
        bands: { light: [["#cfe7e2", 0, 1]], dark: [["#6d2f1e", 0, 1]] },
    },
    bar: {
        dir: "h",
        weight: 0.4,
        bands: { light: [["#efe0bd", 0, 1]], dark: [["#52210f", 0, 1]] },
    },
    page: {
        dir: "v",
        weight: 1.0,
        bands: { light: [["#faf4e6", 0, 1]], dark: [["#12142f", 0, 1]] },
    },
};

interface Faded {
    gradient: string;
    dither: string;
}

export function build(): Record<SurfaceName, Record<Scheme, Faded>> {
    const forSurface = (spec: Surface): Record<Scheme, Faded> => {
        const one = (scheme: Scheme): Faded => ({
            gradient: fadedGradient(spec.bands[scheme], spec.dir, scheme, spec.weight),
            dither: ditherColour(spec.bands[scheme], scheme, spec.weight),
        });
        return { light: one("light"), dark: one("dark") };
    };
    return {
        rail: forSurface(SURFACES.rail),
        barhi: forSurface(SURFACES.barhi),
        bar: forSurface(SURFACES.bar),
        page: forSurface(SURFACES.page),
    };
}
