import { describe, expect, it } from "vitest";
import { parseBreadcrumbs } from "../src/breadcrumbs.js";

describe("parseBreadcrumbs", (): void => {
    it("given a trail with links and a current page, when parsed, then crumbs are returned in order", (): void => {
        const json = JSON.stringify([
            { label: "Cello", href: "/documents/" },
            { label: "Engineering", href: "/documents/engineering/" },
            { label: "A Page" },
        ]);

        expect(parseBreadcrumbs(json)).toEqual([
            { href: "/documents/", label: "Cello" },
            { href: "/documents/engineering/", label: "Engineering" },
            { label: "A Page" },
        ]);
    });

    it("given absent or malformed JSON, when parsed, then it returns an empty trail", (): void => {
        expect(parseBreadcrumbs(null)).toEqual([]);
        expect(parseBreadcrumbs("not json")).toEqual([]);
        expect(parseBreadcrumbs('{"label":"x"}')).toEqual([]);
    });

    it("given items missing a label, when parsed, then they are skipped", (): void => {
        expect(parseBreadcrumbs('[{"href":"/x/"},{"label":"Ok","href":"/ok/"}]')).toEqual([
            { href: "/ok/", label: "Ok" },
        ]);
    });
});
