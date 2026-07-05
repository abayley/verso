// Drives embed_spike against the transformers.js reference vectors and
// reports per-probe cosine similarity. Cosine > 0.999 = shim path verified.
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const ref = JSON.parse(readFileSync("../reference/reference-vectors.json", "utf8"));
const MODELS = {
    "Xenova/all-MiniLM-L6-v2": { pooling: "mean" },
    "Xenova/bge-small-en-v1.5": { pooling: "cls" },
};

const cosine = (a, b) => {
    let dot = 0;
    for (let i = 0; i < a.length; i++) dot += a[i] * b[i];
    return dot; // both unit vectors
};

for (const [id, { pooling }] of Object.entries(MODELS)) {
    const { dims, entries } = ref[id];
    const stdin = entries.map((e) => `${e.input_ids.length} ${e.input_ids.join(" ")}`).join("\n");
    const r = spawnSync(`./embed_spike`, [`../reference/models/${id}/onnx/model.onnx`, pooling, String(dims)], {
        input: stdin,
        encoding: "utf8",
        maxBuffer: 64 * 1024 * 1024,
    });
    if (r.status !== 0) {
        console.error(`${id}: spike failed\n${r.stderr}`);
        process.exit(1);
    }
    const lines = r.stdout.trim().split("\n");
    let worst = 1;
    entries.forEach((e, i) => {
        const got = lines[i].trim().split(/\s+/).map(Number);
        const cos = cosine(got, e.vector);
        worst = Math.min(worst, cos);
        console.log(`${id}  cos=${cos.toFixed(6)}  "${e.text.slice(0, 50)}"`);
    });
    console.log(`${id}  WORST=${worst.toFixed(6)}  ${worst > 0.999 ? "PASS" : "FAIL"}\n`);
}
