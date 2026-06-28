import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { ClientErrorReporter } from "../../src/Verso/Editor/client-error-reporter.js";

describe("ClientErrorReporter", (): void => {
    const beacon = vi.fn((_url: string, _body?: BodyInit | null): boolean => true);

    beforeEach((): void => {
        beacon.mockReset();
        beacon.mockReturnValue(true);
        Object.defineProperty(navigator, "sendBeacon", { configurable: true, value: beacon, writable: true });
    });

    afterEach((): void => {
        vi.restoreAllMocks();
        vi.unstubAllGlobals();
    });

    it("given a failure, when reported, then it posts message, stack, path and kind", (): void => {
        const reporter = new ClientErrorReporter();
        const error = new Error("boom");
        error.stack = "Error: boom\n    at foo (bundle.js:1:2)";

        reporter.report(error, "error");

        expect(beacon).toHaveBeenCalledTimes(1);
        const body = beacon.mock.calls[0]?.[1] as URLSearchParams;
        expect(body.get("message")).toBe("boom");
        expect(body.get("kind")).toBe("error");
        expect(body.get("stack")).toContain("at foo");
        expect(body.get("path")).toBe(window.location.pathname);
    });

    it("given the same failure twice, when reported, then it posts once", (): void => {
        const reporter = new ClientErrorReporter();
        const duplicate = (): Error => {
            const error = new Error("dupe");
            error.stack = "Error: dupe\n    at x";
            return error;
        };

        reporter.report(duplicate(), "error");
        reporter.report(duplicate(), "error");

        expect(beacon).toHaveBeenCalledTimes(1);
    });

    it("given more than ten distinct failures, when reported, then it posts at most ten", (): void => {
        const reporter = new ClientErrorReporter();

        for (let index = 0; index < 15; index += 1) {
            reporter.report(new Error(`error-${index}`), "error");
        }

        expect(beacon).toHaveBeenCalledTimes(10);
    });

    it("given sendBeacon declines, when reported, then it falls back to a keepalive fetch", (): void => {
        beacon.mockReturnValue(false);
        const fetchMock = vi.fn(
            (_url: string, _options?: RequestInit): Promise<Response> =>
                Promise.resolve(new Response(null, { status: 204 })),
        );
        vi.stubGlobal("fetch", fetchMock);

        new ClientErrorReporter().report(new Error("net"), "unhandledrejection");

        expect(fetchMock).toHaveBeenCalledTimes(1);
        const [url, options] = fetchMock.mock.calls[0] ?? ["", undefined];
        expect(url).toBe("/client-errors");
        expect(options?.method).toBe("POST");
        expect(options?.keepalive).toBe(true);
    });
});
