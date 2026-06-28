import { describe, expect, it } from "vitest";
import { isAllowedLinkUri } from "../../src/Verso/Editor/link-uri.js";

const rejectAll = (): boolean => false;
const acceptAll = (): boolean => true;

describe("isAllowedLinkUri", (): void => {
    it("allows a page-relative link even when the default validation would reject it", (): void => {
        expect(isAllowedLinkUri("assets/Spec_Sheet.pdf", rejectAll)).toBe(true);
    });

    it("allows a dot-relative link", (): void => {
        expect(isAllowedLinkUri("./notes.md", rejectAll)).toBe(true);
    });

    it("defers to the default validation for an absolute URL", (): void => {
        expect(isAllowedLinkUri("https://example.com", acceptAll)).toBe(true);
        expect(isAllowedLinkUri("https://example.com", rejectAll)).toBe(false);
    });

    it("blocks a dangerous scheme by deferring to the default validation", (): void => {
        expect(isAllowedLinkUri("javascript:alert(1)", rejectAll)).toBe(false);
    });
});
