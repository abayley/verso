// Spike C reference generator (RFC-0034 phase 0).
// Produces ground-truth tokenisations and embedding vectors with
// transformers.js for fixed probe strings, for two candidate models.
// The ONNX C shim must reproduce these vectors (cosine > 0.999), and the
// pure-Haskell WordPiece tokeniser must reproduce the token ids.
import { AutoTokenizer, env, pipeline } from "@huggingface/transformers";
import { writeFileSync } from "node:fs";

// The sandbox blocks bun's fetch to the HF LFS CDN; models are pre-downloaded
// with curl into ./models (see the spike notes).
env.localModelPath = "./models";
env.allowRemoteModels = false;

const PROBES = [
    "",
    "hello",
    "Hello from MicroHttp",
    "How do I configure SmartWAN failover timeouts?",
    "The quick brown fox jumps over the lazy dog, unbelievably quickly.",
    "error: connection refused (os error 61) while binding 127.0.0.1:8080",
];

const MODELS = [
    { id: "Xenova/all-MiniLM-L6-v2", pooling: "mean" },
    { id: "Xenova/bge-small-en-v1.5", pooling: "cls" },
];

const out = {};
for (const m of MODELS) {
    const tok = await AutoTokenizer.from_pretrained(m.id);
    const embed = await pipeline("feature-extraction", m.id, { dtype: "fp32" });
    const entries = [];
    for (const text of PROBES) {
        const ids = tok(text);
        const vec = await embed(text, { pooling: m.pooling, normalize: true });
        entries.push({
            text,
            input_ids: Array.from(ids.input_ids.data, Number),
            vector: Array.from(vec.data),
        });
    }
    out[m.id] = { pooling: m.pooling, dims: entries[1].vector.length, entries };
    console.log(`${m.id}: ${entries.length} probes, dims=${entries[1].vector.length}`);
}
writeFileSync("reference-vectors.json", JSON.stringify(out));
console.log("wrote reference-vectors.json");
