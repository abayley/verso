// RFC-0034 phase 0: A/B sanity check of bge-small-en-v1.5 vs all-MiniLM-L6-v2
// on real corpus pages and realistic queries. Samples pages, chunks by
// heading with a title context line (mirroring the RFC chunking decision),
// embeds with both models (quantised, as production will), retrieves top-5
// per query, and writes a side-by-side report for human judgement.
import { env, pipeline } from "@huggingface/transformers";
import { readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";

env.localModelPath = "./models";
env.allowRemoteModels = false;

const ROOT = "/Users/alistairbayley/properdocs/cello-docs-work/cello-docs";
const SAMPLE_EVERY = 13; // ~300 of ~3976 pages
const CHUNK_CAP = 1200; // chars, ~ the 384-token cap
const QUERIES = [
    "how do I configure SmartWAN failover",
    "replacing an ESL battery",
    "palo alto firewall software upgrade procedure",
    "onboarding a new staff member",
    "restoring backups for internal infrastructure",
    "customer offboarding process",
    "troubleshooting a VPN connection that keeps dropping",
    "how are spare parts returned and tracked",
];
const MODELS = [
    { id: "Xenova/bge-small-en-v1.5", pooling: "cls", queryPrefix: "" },
    { id: "Xenova/all-MiniLM-L6-v2", pooling: "mean", queryPrefix: "" },
];

const mdFiles = [];
const walk = (dir) => {
    for (const name of readdirSync(dir)) {
        if (name === "meta" || name === "assets" || name.startsWith(".")) continue;
        const p = join(dir, name);
        const st = statSync(p);
        if (st.isDirectory()) walk(p);
        else if (name.endsWith(".md")) mdFiles.push(p);
    }
};
walk(ROOT);
mdFiles.sort();
const sample = mdFiles.filter((_, i) => i % SAMPLE_EVERY === 0);

const chunks = [];
for (const file of sample) {
    let text = readFileSync(file, "utf8");
    let title = relative(ROOT, file);
    const fm = text.match(/^---\n([\s\S]*?)\n---\n/);
    if (fm) {
        const name = fm[1].match(/^name:\s*(.+)$/m);
        if (name) title = name[1].trim();
        text = text.slice(fm[0].length);
    }
    const sections = text.split(/^(?=#{1,3} )/m);
    let anchor = "";
    for (const sec of sections) {
        const h = sec.match(/^#{1,3} (.+)$/m);
        if (h) anchor = h[1].trim();
        const body = sec.trim();
        if (body.length < 60) continue;
        for (let off = 0; off < body.length; off += CHUNK_CAP) {
            const piece = body.slice(off, off + CHUNK_CAP);
            chunks.push({
                page: relative(ROOT, file),
                anchor,
                text: `${title}${anchor ? " > " + anchor : ""}\n${piece}`,
            });
        }
    }
}
console.log(`pages sampled: ${sample.length}, chunks: ${chunks.length}`);

const cosTop = (qv, vecs, k) => {
    const scored = vecs.map((v, i) => {
        let dot = 0;
        for (let d = 0; d < qv.length; d++) dot += qv[d] * v[d];
        return [dot, i];
    });
    scored.sort((a, b) => b[0] - a[0]);
    return scored.slice(0, k);
};

const report = [];
const topsByModel = {};
for (const m of MODELS) {
    const t0 = Date.now();
    const embed = await pipeline("feature-extraction", m.id, { dtype: "q8" });
    const vecs = [];
    const BATCH = 32;
    for (let i = 0; i < chunks.length; i += BATCH) {
        const batch = chunks.slice(i, i + BATCH).map((c) => c.text);
        const out = await embed(batch, { pooling: m.pooling, normalize: true });
        const [n, dims] = out.dims;
        for (let r = 0; r < n; r++) vecs.push(Array.from(out.data.slice(r * dims, (r + 1) * dims)));
        if (i % 640 === 0) console.log(`${m.id}: ${i}/${chunks.length}`);
    }
    topsByModel[m.id] = [];
    for (const q of QUERIES) {
        const qv = await embed(m.queryPrefix + q, { pooling: m.pooling, normalize: true });
        topsByModel[m.id].push(cosTop(Array.from(qv.data), vecs, 5));
    }
    console.log(`${m.id}: embedded ${chunks.length} chunks in ${((Date.now() - t0) / 1000).toFixed(0)}s`);
}

report.push(`# Corpus A/B: bge-small-en-v1.5 vs all-MiniLM-L6-v2`);
report.push(`\n${sample.length} pages sampled, ${chunks.length} chunks, top-5 by cosine.\n`);
QUERIES.forEach((q, qi) => {
    report.push(`\n## Query: ${q}\n`);
    for (const m of MODELS) {
        report.push(`### ${m.id}\n`);
        for (const [score, ci] of topsByModel[m.id][qi]) {
            const c = chunks[ci];
            const firstLine = c.text.split("\n")[1]?.slice(0, 90).replaceAll("|", " ") ?? "";
            report.push(`- ${score.toFixed(3)}  ${c.page}${c.anchor ? " # " + c.anchor : ""}  -- ${firstLine}`);
        }
        report.push("");
    }
    const a = new Set(topsByModel[MODELS[0].id][qi].map(([, i]) => chunks[i].page));
    const b = new Set(topsByModel[MODELS[1].id][qi].map(([, i]) => chunks[i].page));
    const overlap = [...a].filter((p) => b.has(p)).length;
    report.push(`Overlap@5 (pages): ${overlap}/5`);
});
writeFileSync("corpus-ab-report.md", report.join("\n"));
console.log("wrote corpus-ab-report.md");
