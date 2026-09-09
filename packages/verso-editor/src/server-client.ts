/** A successful server operation with its validated value. */
interface ServerSuccess<T> {
    ok: true;
    value: T;
}

/** A failed server operation with a message suitable for the calling UI. */
interface ServerFailure {
    ok: false;
    message: string;
    aborted?: true;
    status?: number;
}

/** The normalised result returned by every editor server operation. */
export type ServerResult<T> = ServerSuccess<T> | ServerFailure;

/** The one message returned when an editor request cannot reach the server. */
export const NETWORK_ERROR = "Couldn’t reach the server.";

/** A navigation tree node returned by the server. */
export interface TreeNodeData {
    name: string;
    path: string;
    kind: "section" | "page";
    hasChildren: boolean;
}

/** A validated entry in the server's trash catalogue. */
export interface TrashEntry {
    id: string;
    path: string;
    kind: string;
}

/** A validated move operation returned for the Undo menu. */
export interface MoveOperation {
    seq: number;
    from: string;
    to: string;
}

/** The successful or refused result of deleting a tree node. */
type TreeDeleteResult = { status: "deleted" } | { status: "refused"; referrers: { page: string; link: string }[] };

/** The validated impact of a move preview or applied move. */
interface TreeMoveResult {
    changed: number;
    to?: string;
}

/** One validated search result. */
export interface SearchResult {
    path: string;
    title: string;
    anchor: string;
    excerpt: string;
}

/** The normalised search response used by the search panel and page. */
export interface SearchResponse {
    enabled: boolean;
    pending: number;
    results: SearchResult[];
}

/** The editor operations supplied by the Verso server. */
export interface ServerClient {
    /** Creates a page or section and returns its edit path. */
    createTreeNode(parentPath: string, kind: "page" | "section", title: string): Promise<ServerResult<string>>;
    /** Deletes a page or section, or returns the links that prevent deletion. */
    deleteTreeNode(path: string): Promise<ServerResult<TreeDeleteResult>>;
    /** Deletes a staged draft. */
    discardDraft(documentPath: string): Promise<ServerResult<void>>;
    /** Permanently deletes one Trash entry. */
    deleteTrashEntry(id: string): Promise<ServerResult<void>>;
    /** Permanently deletes every Trash entry. */
    emptyTrash(): Promise<ServerResult<void>>;
    /** Loads one section's immediate children. */
    loadTreeChildren(path: string): Promise<ServerResult<TreeNodeData[]>>;
    /** Loads raw Markdown from a source URL. */
    loadMarkdown(source: string): Promise<ServerResult<string>>;
    /** Lists a bounded number of recent move operations. */
    listMoves(limit: number): Promise<ServerResult<MoveOperation[]>>;
    /** Lists a bounded number of recent trash entries. */
    listTrash(limit: number): Promise<ServerResult<TrashEntry[]>>;
    /** Previews or applies a page or section move. */
    moveTreeNode(
        path: string,
        destinationParent: string,
        slug: string,
        confirm: boolean,
    ): Promise<ServerResult<TreeMoveResult>>;
    /** Restores a Trash entry to its original tree path. */
    restoreTrashEntry(id: string): Promise<ServerResult<void>>;
    /** Searches published pages, with optional in-flight cancellation. */
    searchPages(query: string, signal?: AbortSignal): Promise<ServerResult<SearchResponse>>;
    /** Saves raw Markdown to a staged draft resource. */
    saveDraft(documentPath: string, markdown: string): Promise<ServerResult<void>>;
    /** Saves raw Markdown to a published document resource. */
    saveDocument(documentPath: string, markdown: string): Promise<ServerResult<void>>;
    /** Synchronises image short titles for one document. */
    syncImageTitles(documentPath: string, parameters: Readonly<Record<string, string>>): Promise<ServerResult<void>>;
    /** Undoes a logged move by sequence number. */
    undoMove(sequence: number): Promise<ServerResult<void>>;
    /** Uploads an attachment and returns its validated stored URL. */
    uploadAttachment(file: File, endpoint: string): Promise<ServerResult<string>>;
}

/** The fetch-compatible dependency used by the HTTP server adapter. */
export type ServerRequest = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

/** Creates the HTTP adapter for the editor's server operations. */
export function createServerClient(request: ServerRequest = defaultRequest): ServerClient {
    return {
        createTreeNode: (parentPath: string, kind: "page" | "section", title: string): Promise<ServerResult<string>> =>
            withNetworkFailure(async (): Promise<ServerResult<string>> => {
                const response = await request(`/tree/${encodePath(parentPath)}`, {
                    method: "POST",
                    headers: { "Content-Type": "application/x-www-form-urlencoded" },
                    body: new URLSearchParams({ kind, title }).toString(),
                });
                if (!response.ok) {
                    return { ok: false, message: "Create failed.", status: response.status };
                }
                const data = safeJson(await response.text());
                const editPath =
                    data && typeof data === "object" ? (data as Record<string, unknown>)["editPath"] : null;
                if (typeof editPath !== "string") {
                    return { ok: false, message: "Create failed." };
                }

                return { ok: true, value: editPath };
            }),
        deleteTreeNode: (path: string): Promise<ServerResult<TreeDeleteResult>> =>
            withNetworkFailure(async (): Promise<ServerResult<TreeDeleteResult>> => {
                const response = await request(`/tree/${encodePath(path)}`, { method: "DELETE" });
                if (response.status === 409) {
                    const data = safeJson(await response.text());
                    const referrers = parseReferrers(data);
                    if (referrers !== null) {
                        return { ok: true, value: { status: "refused", referrers } };
                    }

                    return { ok: false, message: "Delete refused.", status: response.status };
                }
                if (!response.ok) {
                    return { ok: false, message: "Delete failed.", status: response.status };
                }

                return { ok: true, value: { status: "deleted" } };
            }),
        discardDraft: (documentPath: string): Promise<ServerResult<void>> =>
            performOperationRequest(request, `/drafts/${documentPath}`, { method: "DELETE" }, "Discard failed."),
        deleteTrashEntry: (id: string): Promise<ServerResult<void>> =>
            performOperationRequest(
                request,
                `/trash/${encodeURIComponent(id)}`,
                { method: "DELETE" },
                "Could not delete trash entry.",
            ),
        emptyTrash: (): Promise<ServerResult<void>> =>
            performOperationRequest(request, "/trash", { method: "DELETE" }, "Could not empty the trash."),
        loadTreeChildren: (path: string): Promise<ServerResult<TreeNodeData[]>> =>
            withNetworkFailure(async (): Promise<ServerResult<TreeNodeData[]>> => {
                const response = await request(`/tree/${encodePath(path)}`, {
                    headers: { Accept: "application/json" },
                });
                if (!response.ok) {
                    return {
                        ok: false,
                        message: `Failed to load tree children: ${response.status}`,
                        status: response.status,
                    };
                }
                const value = parseTreeChildren(await response.text());

                return { ok: true, value };
            }),
        loadMarkdown: (source: string): Promise<ServerResult<string>> =>
            withNetworkFailure(async (): Promise<ServerResult<string>> => {
                const response = await request(source, { headers: { Accept: "text/markdown" } });
                if (!response.ok) {
                    return {
                        ok: false,
                        message: `Failed to load Markdown document: ${response.status}`,
                        status: response.status,
                    };
                }

                return { ok: true, value: await response.text() };
            }),
        listMoves: (limit: number): Promise<ServerResult<MoveOperation[]>> =>
            withNetworkFailure(async (): Promise<ServerResult<MoveOperation[]>> => {
                const response = await request(`/operations?type=move&limit=${limit}`, {
                    headers: { Accept: "application/json" },
                });
                if (!response.ok) {
                    return { ok: false, message: "Could not load moves.", status: response.status };
                }
                const value = parseMoveOperations(await response.text());

                return { ok: true, value };
            }),
        listTrash: (limit: number): Promise<ServerResult<TrashEntry[]>> =>
            withNetworkFailure(async (): Promise<ServerResult<TrashEntry[]>> => {
                const response = await request(`/trash?limit=${limit}`, { headers: { Accept: "application/json" } });
                if (!response.ok) {
                    return { ok: false, message: "Could not load trash.", status: response.status };
                }
                const value = parseTrashEntries(await response.text());

                return { ok: true, value };
            }),
        moveTreeNode: (
            path: string,
            destinationParent: string,
            slug: string,
            confirm: boolean,
        ): Promise<ServerResult<TreeMoveResult>> =>
            withNetworkFailure(async (): Promise<ServerResult<TreeMoveResult>> => {
                const body = new URLSearchParams({
                    to: destinationParent,
                    slug,
                    ...(confirm ? { confirm: "true" } : {}),
                });
                const response = await request(`/tree/${encodePath(path)}?move`, {
                    method: "POST",
                    headers: { "Content-Type": "application/x-www-form-urlencoded" },
                    body: body.toString(),
                });
                if (!response.ok) {
                    const message = (await response.text()).trim() || "Move failed.";
                    return { ok: false, message, status: response.status };
                }
                const data = safeJson(await response.text());
                const record = data && typeof data === "object" ? (data as Record<string, unknown>) : {};
                const changed = Array.isArray(record["changed"]) ? record["changed"].length : 0;
                const to = record["to"];

                return typeof to === "string" ? { ok: true, value: { changed, to } } : { ok: true, value: { changed } };
            }),
        restoreTrashEntry: (id: string): Promise<ServerResult<void>> =>
            performOperationRequest(request, `/trash/${encodeURIComponent(id)}`, { method: "POST" }, "Restore failed."),
        searchPages: (query: string, signal?: AbortSignal): Promise<ServerResult<SearchResponse>> =>
            withNetworkFailure(async (): Promise<ServerResult<SearchResponse>> => {
                const init: RequestInit = signal === undefined ? {} : { signal };
                const response = await request(`/search?json&q=${encodeURIComponent(query)}`, init);
                if (!response.ok) {
                    return { ok: false, message: "Search failed.", status: response.status };
                }
                const value = parseSearchResponse(await response.text());
                if (value === null) {
                    return { ok: false, message: "Search returned invalid data." };
                }

                return { ok: true, value };
            }),
        saveDraft: (documentPath: string, markdown: string): Promise<ServerResult<void>> =>
            saveMarkdown(request, `/drafts/${documentPath}`, markdown),
        saveDocument: (documentPath: string, markdown: string): Promise<ServerResult<void>> =>
            saveMarkdown(request, `/documents/${documentPath}`, markdown),
        syncImageTitles: (
            documentPath: string,
            parameters: Readonly<Record<string, string>>,
        ): Promise<ServerResult<void>> =>
            performOperationRequest(
                request,
                `/documents/${documentPath}?image-titles`,
                {
                    method: "POST",
                    headers: { "Content-Type": "application/x-www-form-urlencoded" },
                    body: new URLSearchParams(parameters).toString(),
                },
                "Image title synchronisation failed.",
            ),
        undoMove: (sequence: number): Promise<ServerResult<void>> =>
            performOperationRequest(
                request,
                "/undo",
                {
                    method: "POST",
                    headers: { "Content-Type": "application/x-www-form-urlencoded" },
                    body: new URLSearchParams({ seq: String(sequence) }).toString(),
                },
                "Nothing to undo.",
            ),
        uploadAttachment: (file: File, endpoint: string): Promise<ServerResult<string>> =>
            withNetworkFailure(async (): Promise<ServerResult<string>> => {
                const response = await request(endpoint, {
                    body: file,
                    headers: { "X-Attachment-Filename": encodeURIComponent(file.name) },
                    method: "POST",
                });
                if (!response.ok) {
                    return { ok: false, message: uploadErrorMessage(response.status), status: response.status };
                }
                const data = safeJson(await response.text());
                const url = data && typeof data === "object" ? (data as Record<string, unknown>)["url"] : null;
                if (typeof url !== "string") {
                    return { ok: false, message: "The upload returned no URL." };
                }

                return { ok: true, value: url };
            }),
    };
}

/** Saves raw Markdown to one draft or document resource. */
function saveMarkdown(request: ServerRequest, url: string, markdown: string): Promise<ServerResult<void>> {
    return withNetworkFailure(async (): Promise<ServerResult<void>> => {
        const response = await request(url, {
            method: "PUT",
            headers: { "Content-Type": "text/markdown; charset=utf-8" },
            body: markdown,
        });
        if (!response.ok) {
            return { ok: false, message: `HTTP ${response.status}`, status: response.status };
        }

        return { ok: true, value: undefined };
    });
}

/** The live HTTP adapter shared by editor consumers. */
export const editorServerClient: ServerClient = createServerClient();

/** Runs one status-only operation and keeps response text as its failure detail. */
function performOperationRequest(
    request: ServerRequest,
    url: string,
    init: RequestInit,
    failureMessage: string,
): Promise<ServerResult<void>> {
    return withNetworkFailure(async (): Promise<ServerResult<void>> => {
        const response = await request(url, init);
        if (!response.ok) {
            const message = (await response.text()).trim() || failureMessage;
            return { ok: false, message, status: response.status };
        }

        return { ok: true, value: undefined };
    });
}

/** Converts request exceptions into the client's one network failure. */
async function withNetworkFailure<T>(operation: () => Promise<ServerResult<T>>): Promise<ServerResult<T>> {
    try {
        return await operation();
    } catch (error) {
        if (error instanceof DOMException && error.name === "AbortError") {
            return { ok: false, aborted: true, message: "" };
        }
        return { ok: false, message: NETWORK_ERROR };
    }
}

/** Calls the current global fetch implementation. */
function defaultRequest(input: RequestInfo | URL, init?: RequestInit): Promise<Response> {
    return fetch(input, init);
}

/** Percent-encodes each segment while preserving tree path separators. */
function encodePath(path: string): string {
    return path
        .split("/")
        .map((segment): string => encodeURIComponent(segment))
        .join("/");
}

/** Returns the user-facing message for an upload HTTP status. */
function uploadErrorMessage(status: number): string {
    if (status === 413) {
        return "The file is too large to upload.";
    }
    if (status === 415) {
        return "This file type cannot be uploaded.";
    }

    return `The upload failed (status ${status}).`;
}

/** Validates the tree child array returned by the server. */
function parseTreeChildren(json: string): TreeNodeData[] {
    const parsed = safeJson(json);
    if (!Array.isArray(parsed)) {
        return [];
    }

    const nodes: TreeNodeData[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const record = item as Record<string, unknown>;
            const name = record["name"];
            const path = record["path"];
            const kind = record["kind"];
            if (typeof name === "string" && typeof path === "string" && (kind === "section" || kind === "page")) {
                nodes.push({ name, path, kind, hasChildren: record["hasChildren"] === true });
            }
        }
    }

    return nodes;
}

/** Validates the trash entries returned by the server. */
function parseTrashEntries(json: string): TrashEntry[] {
    const parsed = safeJson(json);
    if (!Array.isArray(parsed)) {
        return [];
    }

    const entries: TrashEntry[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const record = item as Record<string, unknown>;
            const id = record["id"];
            const path = record["path"];
            const kind = record["kind"];
            if (typeof id === "string" && typeof path === "string" && typeof kind === "string") {
                entries.push({ id, path, kind });
            }
        }
    }

    return entries;
}

/** Validates the move operations returned by the server. */
function parseMoveOperations(json: string): MoveOperation[] {
    const parsed = safeJson(json);
    if (!Array.isArray(parsed)) {
        return [];
    }

    const moves: MoveOperation[] = [];
    for (const item of parsed) {
        if (item && typeof item === "object") {
            const record = item as Record<string, unknown>;
            const seq = record["seq"];
            const from = record["from"];
            const to = record["to"];
            if (
                record["type"] === "move" &&
                typeof seq === "number" &&
                typeof from === "string" &&
                typeof to === "string"
            ) {
                moves.push({ seq, from, to });
            }
        }
    }

    return moves;
}

/** Validates and normalises the server's search response. */
function parseSearchResponse(json: string): SearchResponse | null {
    const data = safeJson(json);
    if (!data || typeof data !== "object") {
        return null;
    }
    const record = data as Record<string, unknown>;
    if (typeof record["enabled"] !== "boolean") {
        return null;
    }

    const results: SearchResult[] = [];
    const rawResults = record["results"];
    if (rawResults !== undefined && !Array.isArray(rawResults)) {
        return null;
    }
    for (const item of rawResults ?? []) {
        if (item && typeof item === "object") {
            const result = item as Record<string, unknown>;
            const path = result["path"];
            const title = result["title"];
            const anchor = result["anchor"];
            const excerpt = result["excerpt"];
            if (
                typeof path === "string" &&
                typeof title === "string" &&
                typeof anchor === "string" &&
                typeof excerpt === "string"
            ) {
                results.push({ path, title, anchor, excerpt });
            }
        }
    }
    const pending = record["pending"];
    if (pending !== undefined && typeof pending !== "number") {
        return null;
    }

    return { enabled: record["enabled"], pending: pending ?? 0, results };
}

/** Validates the referrer list in a delete refusal response. */
function parseReferrers(data: unknown): { page: string; link: string }[] | null {
    if (!data || typeof data !== "object") {
        return null;
    }
    const value = (data as Record<string, unknown>)["referrers"];
    if (!Array.isArray(value)) {
        return null;
    }

    const referrers: { page: string; link: string }[] = [];
    for (const item of value) {
        if (item && typeof item === "object") {
            const record = item as Record<string, unknown>;
            const page = record["page"];
            const link = record["link"];
            if (typeof page === "string" && typeof link === "string") {
                referrers.push({ page, link });
            }
        }
    }

    return referrers;
}

/** Parses a JSON response without letting malformed server data escape the client. */
function safeJson(json: string): unknown {
    try {
        return JSON.parse(json);
    } catch {
        return null;
    }
}
