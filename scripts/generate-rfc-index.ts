/**
 * Generate the RFC index markdown table from RFC frontmatter.
 *
 * Adapted from the aria-recite generator. micro-http has no `test/e2e/` tier and no
 * `docs/audits/` directory, so the end-to-end test declaration and related-audit checks
 * are dropped; the relationship and placement checks remain.
 */

import path from "node:path";
import { FileSystem } from "@effect/platform";
import { BunFileSystem } from "@effect/platform-bun";
import { Data, Effect, Schema } from "effect";
import matter from "gray-matter";
import { writeStandardError } from "./lib/command-output.js";

const ALLOWED_STATUSES = new Set([
    "Draft",
    "In Progress",
    "Accepted",
    "Implemented",
    "Rejected",
    "Superseded",
    "Evergreen",
]);

const RfcFrontmatterSchema = Schema.Struct({
    child_rfcs: Schema.optional(Schema.Array(Schema.String)),
    design_contract_rfcs: Schema.optional(Schema.Array(Schema.String)),
    id: Schema.String,
    name: Schema.String,
    parent_rfc: Schema.optional(Schema.NullOr(Schema.String)),
    related_rfcs: Schema.optional(Schema.Array(Schema.String)),
    status: Schema.String,
    superseded_by: Schema.optional(Schema.NullOr(Schema.String)),
    supersedes: Schema.optional(Schema.Array(Schema.String)),
});

/** A failed filesystem operation while generating the RFC index. */
export class RfcIndexFileSystemError extends Data.TaggedError("RfcIndexFileSystemError")<{
    readonly operation: "list-rfcs" | "read-index" | "read-rfc" | "write-index";
    readonly path: string;
    readonly cause: unknown;
    readonly message: string;
}> {}

/** Invalid RFC frontmatter or relationships. */
export class RfcIndexContentError extends Data.TaggedError("RfcIndexContentError")<{
    readonly message: string;
    readonly cause?: unknown;
}> {}

/** A generated RFC index that differs from the tracked index. */
export class RfcIndexOutOfDateError extends Data.TaggedError("RfcIndexOutOfDateError")<{
    readonly message: string;
}> {}

export type RfcEntry = {
    childRfcs: string[];
    designContractRfcs: string[];
    id: string;
    name: string;
    parentRfc: string | null;
    relatedRfcs: string[];
    status: string;
    supersededBy: string | null;
    supersedes: string[];
    relativePath: string;
};

/**
 * Normalise a path to forward slashes.
 *
 * @param filePath - Path to the file being inspected.
 * @returns The path with backslashes replaced by forward slashes.
 */
function normalizePath(filePath: string): string {
    return filePath.replaceAll("\\", "/");
}

/**
 * Convert a path to a relative RFC path.
 *
 * @param rfcRoot - RFC root that paths are made relative to.
 * @param filePath - Path to the file being inspected.
 * @returns The RFC path relative to the RFC root.
 */
function asRelativeRfcPath(rfcRoot: string, filePath: string): string {
    return normalizePath(path.relative(rfcRoot, filePath));
}

/**
 * Collect RFC files from the RFC directory tree, excluding supporting refs.
 *
 * @param rootDir - Directory containing the RFC files.
 * @returns Effect that loads the collected RFC file paths.
 */
function collectRfcFiles(
    rootDir: string,
): Effect.Effect<readonly string[], RfcIndexFileSystemError, FileSystem.FileSystem> {
    return Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const entries = yield* fileSystem.readDirectory(rootDir, { recursive: true }).pipe(
            Effect.mapError(
                (cause) =>
                    new RfcIndexFileSystemError({
                        operation: "list-rfcs",
                        path: rootDir,
                        cause,
                        message: `Could not list RFC files under ${rootDir}.`,
                    }),
            ),
        );
        return entries
            .filter((entry) => {
                const name = path.basename(entry);
                if (normalizePath(entry).startsWith("refs/")) {
                    return false;
                }
                return name.startsWith("rfc-") && name.endsWith(".md") && name !== "rfc-template.md";
            })
            .map((entry) => path.join(rootDir, entry))
            .sort((left, right) => left.localeCompare(right));
    });
}

export type RfcIdSortKey = {
    number: number;
    suffix: string;
};

/**
 * Parse an RFC ID into its sortable numeric and suffix parts.
 *
 * @param id - RFC ID to inspect.
 * @returns Parsed ID sort key.
 */
export function parseRfcIdSortKey(id: string): RfcIdSortKey {
    const match = /^RFC-(\d{4})([A-Z]?)$/.exec(id);
    if (!match) {
        throw new Error(`invalid RFC id "${id}"`);
    }
    return {
        number: Number(match[1]),
        suffix: match[2] ?? "",
    };
}

/**
 * Compare RFC entries by ID and path.
 *
 * @param left - Left entry.
 * @param right - Right entry.
 * @returns Sort order.
 */
export function compareRfcEntries(left: RfcEntry, right: RfcEntry): number {
    const leftId = parseRfcIdSortKey(left.id);
    const rightId = parseRfcIdSortKey(right.id);
    if (leftId.number !== rightId.number) {
        return leftId.number - rightId.number;
    }
    const suffixOrder = leftId.suffix.localeCompare(rightId.suffix);
    if (suffixOrder !== 0) {
        return suffixOrder;
    }
    return left.relativePath.localeCompare(right.relativePath);
}

/**
 * Validate one RFC entry's status and directory placement.
 *
 * @param entry - RFC entry to inspect.
 */
function validateEntry(entry: RfcEntry): void {
    if (!ALLOWED_STATUSES.has(entry.status)) {
        throw new Error(`${entry.relativePath}: unsupported status "${entry.status}"`);
    }
    if (entry.status === "Superseded" && entry.supersededBy === null) {
        throw new Error(`${entry.relativePath}: superseded RFCs must set superseded_by`);
    }

    const livesUnderImplemented = entry.relativePath.startsWith("implemented/");
    if (entry.status === "Implemented" && !livesUnderImplemented) {
        throw new Error(`${entry.relativePath}: implemented RFCs must live under docs/rfcs/implemented/`);
    }
    if (entry.status !== "Implemented" && livesUnderImplemented) {
        throw new Error(`${entry.relativePath}: only implemented RFCs may live under docs/rfcs/implemented/`);
    }
}

/**
 * Validate RFC relationship frontmatter against known RFCs.
 *
 * @param entries - RFC entries to validate.
 * @returns Relationship validation errors.
 */
export function validateRfcRelationships(entries: readonly RfcEntry[]): string[] {
    const knownIds = new Set(entries.map((entry) => entry.id));
    const errors: string[] = [];

    const checkOne = (relativePath: string, fieldName: string, rfcId: string | null): void => {
        if (rfcId !== null && !knownIds.has(rfcId)) {
            errors.push(`${relativePath}: ${fieldName} references unknown RFC ID "${rfcId}"`);
        }
    };
    const checkList = (relativePath: string, fieldName: string, rfcIds: readonly string[]): void => {
        for (const rfcId of rfcIds) {
            if (!knownIds.has(rfcId)) {
                errors.push(`${relativePath}: ${fieldName} references unknown RFC ID "${rfcId}"`);
            }
        }
    };

    for (const entry of entries) {
        checkOne(entry.relativePath, "parent_rfc", entry.parentRfc);
        checkOne(entry.relativePath, "superseded_by", entry.supersededBy);
        checkList(entry.relativePath, "child_rfcs", entry.childRfcs);
        checkList(entry.relativePath, "design_contract_rfcs", entry.designContractRfcs);
        checkList(entry.relativePath, "related_rfcs", entry.relatedRfcs);
        checkList(entry.relativePath, "supersedes", entry.supersedes);
    }

    return errors;
}

/**
 * Load one RFC entry from disk.
 *
 * @param rfcRoot - Root used to make the RFC path relative.
 * @param filePath - Path to the RFC file.
 * @returns Effect that loads and validates the RFC entry.
 */
function loadRfcEntry(
    rfcRoot: string,
    filePath: string,
): Effect.Effect<RfcEntry, RfcIndexContentError | RfcIndexFileSystemError, FileSystem.FileSystem> {
    return Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const source = yield* fileSystem.readFileString(filePath).pipe(
            Effect.mapError(
                (cause) =>
                    new RfcIndexFileSystemError({
                        operation: "read-rfc",
                        path: filePath,
                        cause,
                        message: `Could not read RFC file ${filePath}.`,
                    }),
            ),
        );
        const relativePath = asRelativeRfcPath(rfcRoot, filePath);
        const parsed = yield* Effect.try({
            try: () => matter(source),
            catch: (cause) => new RfcIndexContentError({ message: `${relativePath}: invalid frontmatter`, cause }),
        });
        const data = yield* Schema.decodeUnknown(RfcFrontmatterSchema)(parsed.data).pipe(
            Effect.mapError(
                (cause) => new RfcIndexContentError({ message: `${relativePath}: invalid RFC frontmatter`, cause }),
            ),
        );
        return yield* Effect.try({
            try: () => {
                const entry: RfcEntry = {
                    childRfcs: Array.from(data.child_rfcs ?? []),
                    designContractRfcs: Array.from(data.design_contract_rfcs ?? []),
                    id: data.id,
                    name: data.name,
                    parentRfc: data.parent_rfc ?? null,
                    relatedRfcs: Array.from(data.related_rfcs ?? []),
                    status: data.status,
                    supersededBy: data.superseded_by ?? null,
                    supersedes: Array.from(data.supersedes ?? []),
                    relativePath,
                };
                validateEntry(entry);
                return entry;
            },
            catch: (cause) =>
                new RfcIndexContentError({
                    message: cause instanceof Error ? cause.message : String(cause),
                    cause,
                }),
        });
    });
}

/**
 * Render the RFC table as aligned markdown rows.
 *
 * @param entries - RFC entries to render.
 * @returns Rendered table lines.
 */
function renderTable(entries: RfcEntry[]): string[] {
    const headers = ["ID", "Status", "Title"];
    const rows = entries.map((entry) => [`[${entry.id}](${entry.relativePath})`, entry.status, entry.name]);
    const widths = headers.map((header, index) =>
        Math.max(header.length, ...rows.map((row) => row[index]?.length ?? 0)),
    );
    const formatRow = (row: string[]): string =>
        `| ${row.map((cell, index) => cell.padEnd(widths[index] ?? cell.length)).join(" | ")} |`;

    return [formatRow(headers), `| ${widths.map((width) => "-".repeat(width)).join(" | ")} |`, ...rows.map(formatRow)];
}

/**
 * Render the whole RFC index document.
 *
 * @param entries - RFC entries to include.
 * @returns Generated RFC index markdown.
 */
function renderIndex(entries: RfcEntry[]): string {
    const lines = [
        "# RFC Index",
        "",
        "Generated from RFC frontmatter. Do not edit this file manually.",
        "",
        "Implemented RFC files live under `docs/rfcs/implemented/`. All other RFCs remain in `docs/rfcs/`.",
        "",
        ...renderTable(entries),
    ];
    return `${lines.join("\n")}\n`;
}

/**
 * Validate, sort and render all RFC entries without performing input or output.
 *
 * @param entries - RFC entries to include.
 * @returns Generated RFC index markdown.
 */
function buildRfcIndex(entries: readonly RfcEntry[]): string {
    const idSet = new Set<string>();
    for (const entry of entries) {
        if (idSet.has(entry.id)) {
            throw new Error(`duplicate RFC id "${entry.id}"`);
        }
        idSet.add(entry.id);
    }
    const relationshipErrors = validateRfcRelationships(entries);
    if (relationshipErrors.length > 0) {
        throw new Error(`RFC relationship validation failed:\n${relationshipErrors.join("\n")}`);
    }
    return renderIndex(Array.from(entries).sort(compareRfcEntries));
}

/**
 * Generate or check the RFC index through the repository filesystem seam.
 *
 * @param repoRoot - Repository root that contains docs/rfcs.
 * @param checkMode - Whether to compare the generated index without writing it.
 * @returns Effect that returns the number of indexed RFCs.
 */
export function runRfcIndex(
    repoRoot: string,
    checkMode: boolean,
): Effect.Effect<
    number,
    RfcIndexContentError | RfcIndexFileSystemError | RfcIndexOutOfDateError,
    FileSystem.FileSystem
> {
    const rfcRoot = path.join(repoRoot, "docs", "rfcs");
    const indexPath = path.join(rfcRoot, "index.md");
    return Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const rfcFiles = yield* collectRfcFiles(rfcRoot);
        const entries = yield* Effect.forEach(rfcFiles, (filePath) => loadRfcEntry(rfcRoot, filePath), {
            concurrency: "unbounded",
        });
        const generatedIndex = yield* Effect.try({
            try: () => buildRfcIndex(entries),
            catch: (cause) =>
                new RfcIndexContentError({
                    message: cause instanceof Error ? cause.message : String(cause),
                    cause,
                }),
        });

        if (checkMode) {
            const currentIndex = yield* fileSystem.readFileString(indexPath).pipe(
                Effect.mapError(
                    (cause) =>
                        new RfcIndexFileSystemError({
                            operation: "read-index",
                            path: indexPath,
                            cause,
                            message: `Could not read RFC index ${indexPath}.`,
                        }),
                ),
            );
            if (currentIndex !== generatedIndex) {
                return yield* Effect.fail(
                    new RfcIndexOutOfDateError({
                        message: [
                            "RFC index is out of date.",
                            "Run `bun run rfc:index` after changing RFC frontmatter or moving RFC files.",
                        ].join("\n"),
                    }),
                );
            }
            return entries.length;
        }

        yield* fileSystem.writeFileString(indexPath, generatedIndex).pipe(
            Effect.mapError(
                (cause) =>
                    new RfcIndexFileSystemError({
                        operation: "write-index",
                        path: indexPath,
                        cause,
                        message: `Could not write RFC index ${indexPath}.`,
                    }),
            ),
        );
        return entries.length;
    });
}

if (import.meta.main) {
    Effect.runPromise(
        runRfcIndex(process.cwd(), process.argv.includes("--check")).pipe(
            Effect.provide(BunFileSystem.layer),
            Effect.catchAll((error) =>
                Effect.sync(() => {
                    writeStandardError(
                        error._tag === "RfcIndexOutOfDateError"
                            ? error.message
                            : `generate-rfc-index failed: ${error.message}`,
                    );
                    process.exitCode = 1;
                    return 0;
                }),
            ),
        ),
    ).catch((error: unknown) => {
        writeStandardError(`generate-rfc-index failed: ${error instanceof Error ? error.message : String(error)}`);
        process.exitCode = 1;
    });
}
