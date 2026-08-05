/** One match for a sentinel allocated by the protected-fragment pass. */
interface ProtectedFragmentMatch {
    fragmentIndex: number;
    from: number;
    to: number;
}

/** Allocates and recognises the sentinels belonging to one protected-fragment feature. */
export interface ProtectedFragmentMarker {
    find(text: string): readonly ProtectedFragmentMatch[];
    mark(fragmentIndex: number): string;
}

/** The result of finding one feature's fragments before Markdown parsing. */
interface ProtectedFragmentFinding {
    restore(): void;
    stripped: string;
}

/** Fragments found by one feature before Markdown parsing. */
interface FoundProtectedFragments<Fragments> {
    fragments: Fragments;
    stripped: string;
}

/** One feature's extractor, restorer, and declared places in both pass sequences. */
export interface ProtectedFragmentFeatureDefinition<Fragments> {
    find(markdown: string, marker: ProtectedFragmentMarker): FoundProtectedFragments<Fragments>;
    findOrder: number;
    name: string;
    restore(fragments: Fragments, marker: ProtectedFragmentMarker): void;
    restoreOrder: number;
}

/** One protected-fragment feature and its place in the find and restore sequences. */
export interface ProtectedFragmentFeature {
    find(markdown: string, marker: ProtectedFragmentMarker): ProtectedFragmentFinding;
    findOrder: number;
    name: string;
    restoreOrder: number;
}

/** Markdown prepared for the parser, with the matching post-parse restoration pass. */
export interface ProtectedMarkdown {
    restore(): void;
    stripped: string;
}

/** Binds one feature's found fragments to its post-parse restorer. */
export function protectedFragmentFeature<Fragments>(
    definition: ProtectedFragmentFeatureDefinition<Fragments>,
): ProtectedFragmentFeature {
    return {
        find: (markdown: string, marker: ProtectedFragmentMarker): ProtectedFragmentFinding => {
            const found = definition.find(markdown, marker);

            return {
                restore: (): void => definition.restore(found.fragments, marker),
                stripped: found.stripped,
            };
        },
        findOrder: definition.findOrder,
        name: definition.name,
        restoreOrder: definition.restoreOrder,
    };
}

/**
 * Finds protected fragments in declared order and returns one restoration operation for the parsed document.
 * Feature position allocates a disjoint private-use sentinel namespace, so features never coordinate markers.
 */
export function protectMarkdown(markdown: string, features: readonly ProtectedFragmentFeature[]): ProtectedMarkdown {
    const prepared = features.map(
        (feature: ProtectedFragmentFeature, featureIndex: number): PreparedFeature => ({
            feature,
            marker: createMarker(featureIndex),
        }),
    );
    const findings = new Map<ProtectedFragmentFeature, ProtectedFragmentFinding>();
    let stripped = markdown;

    for (const { feature, marker } of orderedBy(prepared, "findOrder")) {
        const finding = feature.find(stripped, marker);
        findings.set(feature, finding);
        stripped = finding.stripped;
    }

    return {
        restore: (): void => {
            for (const { feature } of orderedBy(prepared, "restoreOrder")) {
                findings.get(feature)?.restore();
            }
        },
        stripped,
    };
}

interface PreparedFeature {
    feature: ProtectedFragmentFeature;
    marker: ProtectedFragmentMarker;
}

/** Orders prepared features by one of the two order fields declared on their descriptors. */
function orderedBy(features: readonly PreparedFeature[], field: "findOrder" | "restoreOrder"): PreparedFeature[] {
    return [...features].sort(
        (left: PreparedFeature, right: PreparedFeature): number => left.feature[field] - right.feature[field],
    );
}

/** Creates the private-use sentinel namespace for one feature in the pass. */
function createMarker(featureIndex: number): ProtectedFragmentMarker {
    const pattern = new RegExp(`\\u{E000}${featureIndex}:(\\d+)\\u{E001}`, "gu");

    return {
        find: (text: string): readonly ProtectedFragmentMatch[] => {
            const matches: ProtectedFragmentMatch[] = [];
            let match = pattern.exec(text);

            while (match !== null) {
                matches.push({
                    fragmentIndex: Number(match[1]),
                    from: match.index,
                    to: match.index + match[0].length,
                });
                match = pattern.exec(text);
            }

            pattern.lastIndex = 0;

            return matches;
        },
        mark: (fragmentIndex: number): string => `\u{E000}${featureIndex}:${fragmentIndex}\u{E001}`,
    };
}
