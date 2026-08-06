/** The semantic Callout kinds shared by GFM alerts and MkDocs collapsibles. */
export const CALLOUT_KINDS = ["note", "tip", "important", "warning", "caution"] as const;

export type CalloutKind = (typeof CALLOUT_KINDS)[number];

/** Returns whether an unknown value names a supported Callout kind. */
export function isCalloutKind(value: unknown): value is CalloutKind {
    return CALLOUT_KINDS.includes(value as CalloutKind);
}

/** Returns the default visible title for a Callout kind. */
export function calloutTitle(kind: CalloutKind): string {
    return kind.charAt(0).toUpperCase() + kind.slice(1);
}

/** Returns the Callout kind named by a prefixed class, or null when no supported class is present. */
export function calloutKindFromClassName(classes: DOMTokenList, prefix: string): CalloutKind | null {
    return CALLOUT_KINDS.find((kind: CalloutKind): boolean => classes.contains(`${prefix}-${kind}`)) ?? null;
}
