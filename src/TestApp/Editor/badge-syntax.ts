// Shared badge grammar (RFC-0021), imported by the content extension, the remark span-finder, and the
// Tiptap mark so the recogniser is defined once.

// A leading badge attribute list: exactly `.badge` plus one colour class, tight (`{.badge.red}`) or spaced
// (`{ .badge .red }`). Extra classes, a missing colour, ids or key=value attributes do not match, so they
// stay literal. The colour is any name token, captured in group 1.
export const BADGE_ATTR = /^\{\s*\.badge\s*\.([A-Za-z][\w-]*)\s*\}/;

/** A safe colour token (no CSS metacharacters), gating the inline background-color. */
export const COLOUR_TOKEN = /^[A-Za-z][\w-]*$/;
