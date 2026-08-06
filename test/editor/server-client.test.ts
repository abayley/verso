import { describe, expect, it, vi } from "vitest";
import { createServerClient } from "../../src/Verso/Editor/server-client.js";

describe("server client", (): void => {
    it("given valid tree children, when they are loaded, then it returns validated nodes", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(
                    JSON.stringify([
                        { name: "Guides", path: "guides", kind: "section", hasChildren: true },
                        { name: "Home", path: "index.md", kind: "page", hasChildren: false },
                    ]),
                    { status: 200 },
                ),
        );
        const client = createServerClient(request);

        const result = await client.loadTreeChildren("team notes");

        expect(result).toEqual({
            ok: true,
            value: [
                { name: "Guides", path: "guides", kind: "section", hasChildren: true },
                { name: "Home", path: "index.md", kind: "page", hasChildren: false },
            ],
        });
        expect(request).toHaveBeenCalledWith("/tree/team%20notes", { headers: { Accept: "application/json" } });
    });

    it("given a tree HTTP failure, when children are loaded, then it returns the status failure", async (): Promise<void> => {
        const client = createServerClient(async (): Promise<Response> => new Response("unavailable", { status: 503 }));

        const result = await client.loadTreeChildren("guides");

        expect(result).toEqual({ ok: false, message: "Failed to load tree children: 503", status: 503 });
    });

    it("given a network failure, when children are loaded, then it returns the shared network failure", async (): Promise<void> => {
        const client = createServerClient(async (): Promise<Response> => {
            throw new TypeError("Failed to fetch");
        });

        const result = await client.loadTreeChildren("guides");

        expect(result).toEqual({ ok: false, message: "Couldn’t reach the server." });
    });

    it("given mixed trash data, when the bounded list is loaded, then it returns only validated entries", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(
                    JSON.stringify([
                        { id: "entry-1", path: "guides/old.md", kind: "page" },
                        { id: 2, path: "guides/bad.md", kind: "page" },
                    ]),
                    { status: 200 },
                ),
        );
        const client = createServerClient(request);

        const result = await client.listTrash(10);

        expect(result).toEqual({
            ok: true,
            value: [{ id: "entry-1", path: "guides/old.md", kind: "page" }],
        });
        expect(request).toHaveBeenCalledWith("/trash?limit=10", { headers: { Accept: "application/json" } });
    });

    it("given mixed operations, when recent moves are loaded, then it returns only validated moves", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(
                    JSON.stringify([
                        { seq: 4, type: "move", from: "a.md", to: "guides/a.md" },
                        { seq: 5, type: "delete", path: "old.md" },
                        { seq: "bad", type: "move", from: "b.md", to: "guides/b.md" },
                    ]),
                    { status: 200 },
                ),
        );
        const client = createServerClient(request);

        const result = await client.listMoves(10);

        expect(result).toEqual({ ok: true, value: [{ seq: 4, from: "a.md", to: "guides/a.md" }] });
        expect(request).toHaveBeenCalledWith("/operations?type=move&limit=10", {
            headers: { Accept: "application/json" },
        });
    });

    it("given a new page request, when it is created, then it returns the validated edit path", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(JSON.stringify({ editPath: "guides/new-page.md" }), { status: 200 }),
        );
        const client = createServerClient(request);

        const result = await client.createTreeNode("team notes", "page", "New page");

        expect(result).toEqual({ ok: true, value: "guides/new-page.md" });
        expect(request).toHaveBeenCalledWith("/tree/team%20notes", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: "kind=page&title=New+page",
        });
    });

    it("given a referenced page, when deletion is refused, then it returns validated referrers", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(JSON.stringify({ referrers: [{ page: "index.md", link: "guides/old.md" }] }), {
                    status: 409,
                }),
        );
        const client = createServerClient(request);

        const result = await client.deleteTreeNode("guides/old page.md");

        expect(result).toEqual({
            ok: true,
            value: { status: "refused", referrers: [{ page: "index.md", link: "guides/old.md" }] },
        });
        expect(request).toHaveBeenCalledWith("/tree/guides/old%20page.md", { method: "DELETE" });
    });

    it("given a confirmed move, when it is applied, then it returns the validated impact", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(JSON.stringify({ changed: ["index.md", "guides/index.md"], to: "guides/new.md" }), {
                    status: 200,
                }),
        );
        const client = createServerClient(request);

        const result = await client.moveTreeNode("old page.md", "guides", "new.md", true);

        expect(result).toEqual({ ok: true, value: { changed: 2, to: "guides/new.md" } });
        expect(request).toHaveBeenCalledWith("/tree/old%20page.md?move", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: "to=guides&slug=new.md&confirm=true",
        });
    });

    it("given a move sequence, when it is undone, then it posts the selected sequence", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.undoMove(42);

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/undo", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: "seq=42",
        });
    });

    it("given a trash entry, when it is restored, then it posts the encoded entry id", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.restoreTrashEntry("entry / 1");

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/trash/entry%20%2F%201", { method: "POST" });
    });

    it("given a trash entry, when it is permanently deleted, then it deletes the encoded entry id", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.deleteTrashEntry("entry / 1");

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/trash/entry%20%2F%201", { method: "DELETE" });
    });

    it("given an empty Trash request, when it is applied, then it deletes the unbounded Trash resource", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.emptyTrash();

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/trash", { method: "DELETE" });
    });

    it("given valid search data, when pages are searched, then it returns a normalised response", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(
                    JSON.stringify({
                        enabled: true,
                        pending: 2,
                        results: [
                            {
                                path: "guides/failover.md",
                                title: "Failover",
                                anchor: "Timeouts",
                                excerpt: "Configure the timeout.",
                            },
                        ],
                    }),
                    { status: 200 },
                ),
        );
        const client = createServerClient(request);
        const controller = new AbortController();

        const result = await client.searchPages("fail over", controller.signal);

        expect(result).toEqual({
            ok: true,
            value: {
                enabled: true,
                pending: 2,
                results: [
                    {
                        path: "guides/failover.md",
                        title: "Failover",
                        anchor: "Timeouts",
                        excerpt: "Configure the timeout.",
                    },
                ],
            },
        });
        expect(request).toHaveBeenCalledWith("/search?json&q=fail%20over", { signal: controller.signal });
    });

    it("given an aborted search, when the request stops, then it returns a silent cancellation", async (): Promise<void> => {
        const client = createServerClient(async (): Promise<Response> => {
            throw new DOMException("The operation was aborted.", "AbortError");
        });

        const result = await client.searchPages("failover");

        expect(result).toEqual({ ok: false, aborted: true, message: "" });
    });

    it("given an attachment, when it is uploaded, then it returns the validated stored URL", async (): Promise<void> => {
        const request = vi.fn(
            async (): Promise<Response> =>
                new Response(JSON.stringify({ url: "/attachments/abc/a b.png" }), { status: 200 }),
        );
        const client = createServerClient(request);
        const file = new File([new Uint8Array([1, 2, 3])], "a b.png", { type: "image/png" });

        const result = await client.uploadAttachment(file, "/attachments");

        expect(result).toEqual({ ok: true, value: "/attachments/abc/a b.png" });
        expect(request).toHaveBeenCalledWith("/attachments", {
            body: file,
            headers: { "X-Attachment-Filename": "a%20b.png" },
            method: "POST",
        });
    });

    it("given an oversized attachment, when upload is refused, then it returns the size message", async (): Promise<void> => {
        const client = createServerClient(async (): Promise<Response> => new Response(null, { status: 413 }));
        const file = new File([new Uint8Array([1])], "large.png", { type: "image/png" });

        const result = await client.uploadAttachment(file, "/attachments");

        expect(result).toEqual({
            ok: false,
            message: "The file is too large to upload.",
            status: 413,
        });
    });

    it("given a disallowed attachment, when upload is refused, then it returns the file type message", async (): Promise<void> => {
        const client = createServerClient(async (): Promise<Response> => new Response(null, { status: 415 }));
        const file = new File([new Uint8Array([1])], "program.exe", { type: "application/octet-stream" });

        const result = await client.uploadAttachment(file, "/attachments");

        expect(result).toEqual({
            ok: false,
            message: "This file type cannot be uploaded.",
            status: 415,
        });
    });

    it("given draft Markdown, when it is saved, then it puts the raw body to the draft resource", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.saveDraft("guides/fail over.md", "# Fail over\n");

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/drafts/guides/fail over.md", {
            method: "PUT",
            headers: { "Content-Type": "text/markdown; charset=utf-8" },
            body: "# Fail over\n",
        });
    });

    it("given published Markdown, when it is saved, then it puts the raw body to the document resource", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.saveDocument("guides/failover.md", "# Failover\n");

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/documents/guides/failover.md", {
            method: "PUT",
            headers: { "Content-Type": "text/markdown; charset=utf-8" },
            body: "# Failover\n",
        });
    });

    it("given a staged draft, when it is discarded, then it deletes the draft resource", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.discardDraft("guides/failover.md");

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/drafts/guides/failover.md", { method: "DELETE" });
    });

    it("given a Markdown source, when it is loaded, then it returns the response text", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response("# Failover\n", { status: 200 }));
        const client = createServerClient(request);

        const result = await client.loadMarkdown("/documents/guides/failover.md?raw");

        expect(result).toEqual({ ok: true, value: "# Failover\n" });
        expect(request).toHaveBeenCalledWith("/documents/guides/failover.md?raw", {
            headers: { Accept: "text/markdown" },
        });
    });

    it("given image titles, when they are synchronised, then it posts form data to the document controller", async (): Promise<void> => {
        const request = vi.fn(async (): Promise<Response> => new Response(null, { status: 204 }));
        const client = createServerClient(request);

        const result = await client.syncImageTitles("guides/failover.md", {
            image_count: "1",
            image_0_path: "assets/map.png",
            image_0_title: "Failover map",
        });

        expect(result).toEqual({ ok: true, value: undefined });
        expect(request).toHaveBeenCalledWith("/documents/guides/failover.md?image-titles", {
            method: "POST",
            headers: { "Content-Type": "application/x-www-form-urlencoded" },
            body: "image_count=1&image_0_path=assets%2Fmap.png&image_0_title=Failover+map",
        });
    });
});
