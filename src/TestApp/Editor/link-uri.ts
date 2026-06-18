// Whether a link URL may keep its href in the visual editor. Page-relative links (`assets/x.pdf`,
// RFC-0019) have no URI scheme, and Tiptap's default href sanitisation drops scheme-less URLs to an empty
// href. This permits scheme-less (relative) URLs while deferring to Tiptap's default validation for
// absolute ones, so dangerous schemes (`javascript:`, `data:`) stay blocked.

/** A URL begins with a scheme when it starts with a letter followed by scheme characters and a colon. */
const HAS_SCHEME = /^[a-z][a-z0-9+.-]*:/i;

/**
 * Whether the visual editor should keep a link's href. Scheme-less (relative) URLs are allowed outright;
 * URLs carrying a scheme defer to Tiptap's default validation, preserving its protocol allow-list.
 */
export function isAllowedLinkUri(url: string, defaultValidate: (candidate: string) => boolean): boolean {
    return HAS_SCHEME.test(url) ? defaultValidate(url) : true;
}
