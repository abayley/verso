/**
 * Generate the ADR index markdown table from ADR frontmatter and decision sections.
 */

import path from "node:path";
import { FileSystem } from "@effect/platform";
import { BunFileSystem } from "@effect/platform-bun";
import { Data, Effect, Schema } from "effect";
import matter from "gray-matter";
import { writeStandardError } from "./lib/command-output.js";

const ALLOWED_STATUSES = new Set(["Proposed", "Accepted", "Superseded", "Deprecated"]);

const AdrFrontmatterSchema = Schema.Struct({
    id: Schema.String,
    name: Schema.String,
    related_rfcs: Schema.optional(Schema.Array(Schema.String)),
    status: Schema.String,
    superseded_by: Schema.optional(Schema.NullOr(Schema.String)),
    supersedes: Schema.optional(Schema.Array(Schema.String)),
});

/** A failed filesystem operation while generating the ADR index. */
export class AdrIndexFileSystemError extends Data.TaggedError("AdrIndexFileSystemError")<{
    readonly operation: "list-adrs" | "read-adr" | "read-index" | "write-index";
    readonly path: string;
    readonly cause: unknown;
    readonly message: string;
}> {}

/** Invalid ADR frontmatter, sections or relationships. */
export class AdrIndexContentError extends Data.TaggedError("AdrIndexContentError")<{
    readonly message: string;
    readonly cause?: unknown;
}> {}

/** A generated ADR index that differs from the tracked index. */
export class AdrIndexOutOfDateError extends Data.TaggedError("AdrIndexOutOfDateError")<{
    readonly message: string;
}> {}

export type AdrEntry = {
    decision: string;
    id: string;
    name: string;
    relatedRfcs: string[];
    relativePath: string;
    status: string;
    supersededBy: string | null;
    supersedes: string[];
};

/**
 * Collect ADR files from the ADR directory.
 *
 * @param rootDir - Directory containing the ADR files.
 * @returns Effect that loads the collected ADR file paths.
 */
function collectAdrFiles(
    rootDir: string,
): Effect.Effect<readonly string[], AdrIndexFileSystemError, FileSystem.FileSystem> {
    return Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const entries = yield* fileSystem.readDirectory(rootDir).pipe(
            Effect.mapError(
                (cause) =>
                    new AdrIndexFileSystemError({
                        operation: "list-adrs",
                        path: rootDir,
                        cause,
                        message: `Could not list ADR files under ${rootDir}.`,
                    }),
            ),
        );
        return entries
            .filter((entry) => entry.startsWith("adr-") && entry.endsWith(".md") && entry !== "adr-template.md")
            .map((entry) => path.join(rootDir, entry))
            .sort((left, right) => left.localeCompare(right));
    });
}

/**
 * Parse an ADR ID into its sortable number.
 *
 * @param id - ADR ID to inspect.
 * @returns Parsed ADR number.
 */
export function parseAdrIdNumber(id: string): number {
    const match = /^ADR-(\d{4})$/.exec(id);
    if (!match) {
        throw new Error(`invalid ADR id "${id}"`);
    }
    return Number(match[1]);
}

/**
 * Read the decision statement from an ADR body.
 *
 * The index quotes the decision rather than repeating it in frontmatter, so the ADR file stays the
 * single place the decision is written down.
 *
 * @param relativePath - ADR path used in error messages.
 * @param body - ADR markdown body without frontmatter.
 * @returns The first paragraph of the decision section, as one line.
 */
export function readDecisionStatement(relativePath: string, body: string): string {
    const lines = body.split("\n");
    const headingIndex = lines.findIndex((line) => line.trim() === "## Decision");
    if (headingIndex === -1) {
        throw new Error(`${relativePath}: missing "## Decision" section`);
    }
    const paragraph: string[] = [];
    for (const line of lines.slice(headingIndex + 1)) {
        const trimmed = line.trim();
        if (trimmed.startsWith("#")) {
            break;
        }
        if (trimmed.length === 0) {
            if (paragraph.length > 0) {
                break;
            }
            continue;
        }
        paragraph.push(trimmed);
    }
    if (paragraph.length === 0) {
        throw new Error(`${relativePath}: empty "## Decision" section`);
    }
    return paragraph.join(" ");
}

/**
 * Validate one ADR entry.
 *
 * @param entry - ADR entry to inspect.
 */
function validateEntry(entry: AdrEntry): void {
    if (!ALLOWED_STATUSES.has(entry.status)) {
        throw new Error(`${entry.relativePath}: unsupported status "${entry.status}"`);
    }
    if (entry.status === "Superseded" && entry.supersededBy === null) {
        throw new Error(`${entry.relativePath}: superseded ADRs must set superseded_by`);
    }
    if (entry.status !== "Superseded" && entry.supersededBy !== null) {
        throw new Error(`${entry.relativePath}: superseded_by is only allowed on superseded ADRs`);
    }
    const expectedPath = `${entry.id.toLowerCase()}-`;
    if (!entry.relativePath.startsWith(expectedPath)) {
        throw new Error(`${entry.relativePath}: filename must start with "${expectedPath}"`);
    }
}

/**
 * Validate ADR supersession links against known ADRs.
 *
 * @param entries - ADR entries to validate.
 * @returns Relationship validation errors.
 */
export function validateAdrRelationships(entries: readonly AdrEntry[]): string[] {
    const knownIds = new Set(entries.map((entry) => entry.id));
    const errors: string[] = [];

    for (const entry of entries) {
        if (entry.supersededBy !== null && !knownIds.has(entry.supersededBy)) {
            errors.push(`${entry.relativePath}: superseded_by references unknown ADR ID "${entry.supersededBy}"`);
        }
        for (const supersededId of entry.supersedes) {
            if (!knownIds.has(supersededId)) {
                errors.push(`${entry.relativePath}: supersedes references unknown ADR ID "${supersededId}"`);
            }
        }
    }

    return errors;
}

/**
 * Load one ADR entry from disk.
 *
 * @param adrRoot - Root used to make the ADR path relative.
 * @param filePath - Path to the ADR file.
 * @returns Effect that loads and validates the ADR entry.
 */
function loadAdrEntry(
    adrRoot: string,
    filePath: string,
): Effect.Effect<AdrEntry, AdrIndexContentError | AdrIndexFileSystemError, FileSystem.FileSystem> {
    return Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const source = yield* fileSystem.readFileString(filePath).pipe(
            Effect.mapError(
                (cause) =>
                    new AdrIndexFileSystemError({
                        operation: "read-adr",
                        path: filePath,
                        cause,
                        message: `Could not read ADR file ${filePath}.`,
                    }),
            ),
        );
        const relativePath = path.relative(adrRoot, filePath).replaceAll("\\", "/");
        const parsed = yield* Effect.try({
            try: () => matter(source),
            catch: (cause) => new AdrIndexContentError({ message: `${relativePath}: invalid frontmatter`, cause }),
        });
        const data = yield* Schema.decodeUnknown(AdrFrontmatterSchema)(parsed.data).pipe(
            Effect.mapError(
                (cause) => new AdrIndexContentError({ message: `${relativePath}: invalid ADR frontmatter`, cause }),
            ),
        );
        return yield* Effect.try({
            try: () => {
                const entry: AdrEntry = {
                    decision: readDecisionStatement(relativePath, parsed.content),
                    id: data.id,
                    name: data.name,
                    relatedRfcs: Array.from(data.related_rfcs ?? []),
                    relativePath,
                    status: data.status,
                    supersededBy: data.superseded_by ?? null,
                    supersedes: Array.from(data.supersedes ?? []),
                };
                validateEntry(entry);
                return entry;
            },
            catch: (cause) =>
                new AdrIndexContentError({
                    message: cause instanceof Error ? cause.message : String(cause),
                    cause,
                }),
        });
    });
}

/**
 * Render the ADR table as aligned markdown rows.
 *
 * @param entries - ADR entries to render.
 * @returns Rendered table lines.
 */
function renderTable(entries: AdrEntry[]): string[] {
    const headers = ["ID", "Status", "RFCs", "Decision", "Choice"];
    const rows = entries.map((entry) => [
        `[${entry.id}](${entry.relativePath})`,
        entry.status,
        entry.relatedRfcs.join(", "),
        entry.name,
        entry.decision,
    ]);
    const widths = headers.map((header, index) =>
        Math.max(header.length, ...rows.map((row) => row[index]?.length ?? 0)),
    );
    const formatRow = (row: string[]): string =>
        `| ${row.map((cell, index) => cell.padEnd(widths[index] ?? cell.length)).join(" | ")} |`;

    return [formatRow(headers), `| ${widths.map((width) => "-".repeat(width)).join(" | ")} |`, ...rows.map(formatRow)];
}

/**
 * Render the whole ADR index document.
 *
 * @param entries - ADR entries to include.
 * @returns Generated ADR index markdown.
 */
function renderIndex(entries: AdrEntry[]): string {
    const lines = [
        "# ADR Index",
        "",
        "Generated from ADR frontmatter and each ADR's decision section. Do not edit this file manually.",
        "",
        "Each row states what was decided. The reason and the condition that would reopen the decision live in",
        "the ADR file itself. Run `bun run adr:index` after adding an ADR or changing ADR frontmatter.",
        "",
        ...renderTable(entries),
    ];
    return `${lines.join("\n")}\n`;
}

/**
 * Validate, sort and render all ADR entries without performing input or output.
 *
 * @param entries - ADR entries to include.
 * @returns Generated ADR index markdown.
 */
function buildAdrIndex(entries: readonly AdrEntry[]): string {
    const idSet = new Set<string>();
    for (const entry of entries) {
        if (idSet.has(entry.id)) {
            throw new Error(`duplicate ADR id "${entry.id}"`);
        }
        idSet.add(entry.id);
    }
    const relationshipErrors = validateAdrRelationships(entries);
    if (relationshipErrors.length > 0) {
        throw new Error(`ADR relationship validation failed:\n${relationshipErrors.join("\n")}`);
    }
    const sorted = Array.from(entries).sort((left, right) => parseAdrIdNumber(left.id) - parseAdrIdNumber(right.id));
    return renderIndex(sorted);
}

/**
 * Generate or check the ADR index through the repository filesystem seam.
 *
 * @param repoRoot - Repository root that contains docs/adrs.
 * @param checkMode - Whether to compare the generated index without writing it.
 * @returns Effect that returns the number of indexed ADRs.
 */
export function runAdrIndex(
    repoRoot: string,
    checkMode: boolean,
): Effect.Effect<
    number,
    AdrIndexContentError | AdrIndexFileSystemError | AdrIndexOutOfDateError,
    FileSystem.FileSystem
> {
    const adrRoot = path.join(repoRoot, "docs", "adrs");
    const indexPath = path.join(adrRoot, "index.md");
    return Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const adrFiles = yield* collectAdrFiles(adrRoot);
        const entries = yield* Effect.forEach(adrFiles, (filePath) => loadAdrEntry(adrRoot, filePath), {
            concurrency: "unbounded",
        });
        const generatedIndex = yield* Effect.try({
            try: () => buildAdrIndex(entries),
            catch: (cause) =>
                new AdrIndexContentError({
                    message: cause instanceof Error ? cause.message : String(cause),
                    cause,
                }),
        });

        if (checkMode) {
            const currentIndex = yield* fileSystem.readFileString(indexPath).pipe(
                Effect.mapError(
                    (cause) =>
                        new AdrIndexFileSystemError({
                            operation: "read-index",
                            path: indexPath,
                            cause,
                            message: `Could not read ADR index ${indexPath}.`,
                        }),
                ),
            );
            if (currentIndex !== generatedIndex) {
                return yield* Effect.fail(
                    new AdrIndexOutOfDateError({
                        message: [
                            "ADR index is out of date.",
                            "Run `bun run adr:index` after changing ADR frontmatter or adding an ADR.",
                        ].join("\n"),
                    }),
                );
            }
            return entries.length;
        }

        yield* fileSystem.writeFileString(indexPath, generatedIndex).pipe(
            Effect.mapError(
                (cause) =>
                    new AdrIndexFileSystemError({
                        operation: "write-index",
                        path: indexPath,
                        cause,
                        message: `Could not write ADR index ${indexPath}.`,
                    }),
            ),
        );
        return entries.length;
    });
}

if (import.meta.main) {
    Effect.runPromise(
        runAdrIndex(process.cwd(), process.argv.includes("--check")).pipe(
            Effect.provide(BunFileSystem.layer),
            Effect.catchAll((error) =>
                Effect.sync(() => {
                    writeStandardError(
                        error._tag === "AdrIndexOutOfDateError"
                            ? error.message
                            : `generate-adr-index failed: ${error.message}`,
                    );
                    process.exitCode = 1;
                    return 0;
                }),
            ),
        ),
    ).catch((error: unknown) => {
        writeStandardError(`generate-adr-index failed: ${error instanceof Error ? error.message : String(error)}`);
        process.exitCode = 1;
    });
}
