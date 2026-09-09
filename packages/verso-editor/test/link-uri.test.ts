import { describe, expect, it } from "vitest";
import { isAllowedLinkUri } from "../src/link-uri.js";

const rejectAll = (): boolean => false;
const acceptAll = (): boolean => true;

describe("isAllowedLinkUri", (): void => {
    it("given a page-relative link the default validation rejects, when it is checked, then it is allowed", (): void => {
        expect(isAllowedLinkUri("assets/Spec_Sheet.pdf", rejectAll)).toBe(true);
    });

    it("given a dot-relative link, when it is checked, then it is allowed", (): void => {
        expect(isAllowedLinkUri("./notes.md", rejectAll)).toBe(true);
    });

    it("given an absolute URL, when it is checked, then the default validation decides", (): void => {
        expect(isAllowedLinkUri("https://example.com", acceptAll)).toBe(true);
        expect(isAllowedLinkUri("https://example.com", rejectAll)).toBe(false);
    });

    it("given a dangerous scheme, when it is checked, then the default validation blocks it", (): void => {
        expect(isAllowedLinkUri("javascript:alert(1)", rejectAll)).toBe(false);
    });
});
