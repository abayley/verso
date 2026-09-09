import { defineConfig } from "vitest/config";

export default defineConfig({
    test: {
        // Runs before every test file; see test/editor/setup.ts for why.
        setupFiles: ["test/setup.ts"],
    },
});
