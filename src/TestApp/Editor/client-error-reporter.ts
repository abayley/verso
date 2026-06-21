// Client-error telemetry (RFC-0023). The editor's error boundary hands every surfaced failure to a
// reporter, which posts a bounded, de-duplicated report to the server's POST /client-errors endpoint
// fire-and-forget. Telemetry is best-effort: it must never throw back into the editor.

const CLIENT_ERROR_ENDPOINT = "/client-errors";
const MAX_REPORTS_PER_SESSION = 10;

/** Which boundary caught the failure. */
export type ClientErrorKind = "error" | "unhandledrejection";

/** Posts bounded, de-duplicated client-error reports to the server, fire-and-forget (RFC-0023). */
export class ClientErrorReporter {
    private readonly seen = new Set<string>();
    private sent = 0;

    /** Reports a failure once per distinct (message, first stack frame) and at most per-session cap times. */
    report(error: unknown, kind: ClientErrorKind): void {
        if (this.sent >= MAX_REPORTS_PER_SESSION) {
            return;
        }

        const message = describeError(error);
        const stack = errorStack(error);
        const key = `${message}\n${stack.split("\n", 1)[0] ?? ""}`;

        if (this.seen.has(key)) {
            return;
        }

        this.seen.add(key);
        this.sent += 1;
        this.post(message, stack, kind);
    }

    /** Sends one report via sendBeacon (survives page unload), falling back to a keepalive fetch. */
    private post(message: string, stack: string, kind: ClientErrorKind): void {
        const body = new URLSearchParams({ kind, message, path: window.location.pathname, stack });

        try {
            if (typeof navigator !== "undefined" && typeof navigator.sendBeacon === "function") {
                if (navigator.sendBeacon(CLIENT_ERROR_ENDPOINT, body)) {
                    return;
                }
            }

            void fetch(CLIENT_ERROR_ENDPOINT, { body, keepalive: true, method: "POST" }).catch((): void => {});
        } catch {
            // Best-effort: a failed report must never disturb the editor.
        }
    }
}

/** A human-readable message for any thrown value. */
function describeError(error: unknown): string {
    return error instanceof Error ? error.message : String(error);
}

/** The stack trace of an Error, or an empty string for any other thrown value. */
function errorStack(error: unknown): string {
    return error instanceof Error && typeof error.stack === "string" ? error.stack : "";
}
