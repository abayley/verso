/** Writes human-facing command output without treating it as structured application logging. */

export interface CommandOutput {
    writeStandardError(message: string): void;
    writeStandardOutput(message: string): void;
}

/**
 * Creates line-oriented command output from injected stream writers.
 *
 * @param writeStdout Raw standard output writer.
 * @param writeStderr Raw standard error writer.
 * @returns Human-facing line writers for both streams.
 */
export function createCommandOutput(
    writeStdout: (text: string) => unknown,
    writeStderr: (text: string) => unknown,
): CommandOutput {
    return {
        writeStandardOutput: (message) => {
            writeStdout(`${message}\n`);
        },
        writeStandardError: (message) => {
            writeStderr(`${message}\n`);
        },
    };
}

const standardCommandOutput = createCommandOutput(
    (text) => process.stdout.write(text),
    (text) => process.stderr.write(text),
);

export const { writeStandardError, writeStandardOutput } = standardCommandOutput;
