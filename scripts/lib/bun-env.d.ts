// Minimal ambient declaration for the Bun-only `import.meta.main` flag used by
// the index generator scripts, so `tsc` can typecheck them without pulling in
// the full bun-types package.
interface ImportMeta {
    readonly main: boolean;
}
