// Shared badge grammar (RFC-0021), imported by the content extension, the remark span-finder, and the
// Tiptap mark so the recogniser is defined once.

// A leading badge attribute list: exactly `.badge` plus one colour class, tight (`{.badge.red}`) or spaced
// (`{ .badge .red }`). Extra classes, a missing colour, ids or key=value attributes do not match, so they
// stay literal. The colour is any name token, captured in group 1.
export const BADGE_ATTR = /^\{\s*\.badge\s*\.([A-Za-z][\w-]*)\s*\}/;

/** A safe colour token (no CSS metacharacters), gating the inline background-color. */
export const COLOUR_TOKEN = /^[A-Za-z][\w-]*$/;

/** The common colours offered by the badge control (parsing still accepts any colour name). */
export const COMMON_BADGE_COLOURS = ["yellow", "red", "green", "orange", "blue", "purple", "gray", "black"] as const;

/**
 * A black or white foreground that reads on the given CSS colour used as a badge background, or null when
 * the colour is not a valid CSS colour (the badge then keeps the theme's text colour). The colour is
 * resolved to RGB via a canvas (which normalises any valid CSS colour) and its perceived luminance picks
 * the contrasting foreground.
 */
function badgeForeground(colour: string): "#000000" | "#ffffff" | null {
    try {
        const context = document.createElement("canvas").getContext("2d");

        if (!context) {
            return null;
        }

        // An invalid colour leaves fillStyle unchanged, so probe against two sentinels to detect validity.
        context.fillStyle = "#000000";
        context.fillStyle = colour;
        if (context.fillStyle === "#000000") {
            context.fillStyle = "#ffffff";
            context.fillStyle = colour;
            if (context.fillStyle === "#ffffff") {
                return null;
            }
            return "#ffffff";
        }

        const hex = context.fillStyle;
        const match = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(hex);

        if (!match) {
            return null;
        }

        const r = Number.parseInt(match[1] ?? "0", 16);
        const g = Number.parseInt(match[2] ?? "0", 16);
        const b = Number.parseInt(match[3] ?? "0", 16);

        return (r * 299 + g * 587 + b * 114) / 1000 > 140 ? "#000000" : "#ffffff";
    } catch {
        return null;
    }
}

/**
 * The inline style for a badge pill: the colour as the background, plus a contrasting foreground when one
 * can be computed. The caller must have validated the colour with {@link COLOUR_TOKEN} (no CSS injection).
 */
export function badgeStyle(colour: string): string {
    const foreground = badgeForeground(colour);

    return foreground ? `background-color: ${colour}; color: ${foreground}` : `background-color: ${colour}`;
}
