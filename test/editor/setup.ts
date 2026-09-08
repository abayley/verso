// Test setup: no test may reach the network.
//
// The editor element builds a SearchPanel and fires `connect()` without awaiting it, which
// asks the server whether search is enabled. Under happy-dom that became a real request to
// its default origin: 217 lines of `GET http://localhost:3000/search?json&q= 404` per run,
// and then an AbortError stack trace when the still-pending request was cancelled at window
// teardown. Both came from one unstubbed fetch.
//
// Refusing rather than answering: the client wraps its requests in a network-failure guard,
// so a rejected fetch takes the same "search unavailable" path a 404 took, and a test that
// starts depending on a real request fails with a message naming the URL instead of quietly
// talking to whatever is listening on port 3000.
const refuse = (input: RequestInfo | URL): Promise<Response> =>
    Promise.reject(new Error(`unstubbed fetch in a test: ${String(input)}`));

globalThis.fetch = refuse as unknown as typeof globalThis.fetch;
