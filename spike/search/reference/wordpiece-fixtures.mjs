// Generates the Concordance.WordPiece reference fixtures (RFC-0034 phase 1):
// the real bge-small-en-v1.5 vocab.txt (extracted from tokenizer.json) and
// reference tokenisations of probe strings produced by the genuine
// HuggingFace tokenizer. Output goes to test/integration/Concordance/
// fixtures/ in a line-oriented format (text line, then id line) so the
// Haskell integration spec needs no JSON parser.
//
// Run from spike/search/reference (where @huggingface/transformers is
// installed): bun wordpiece-fixtures.mjs
// Requires the spike model downloads (spike/search/reference/models).
import { AutoTokenizer, env } from "@huggingface/transformers";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "../../..");
env.localModelPath = join(ROOT, "spike/search/reference/models");
env.allowRemoteModels = false;

const MODEL = "Xenova/bge-small-en-v1.5";
const OUT = join(ROOT, "test/integration/Concordance/fixtures");

const PROBES = [
    "",
    "hello",
    "Hello from MicroHttp",
    "How do I configure SmartWAN failover timeouts?",
    "The quick brown fox jumps over the lazy dog, unbelievably quickly.",
    "error: connection refused (os error 61) while binding 127.0.0.1:8080",
    "Café naïve résumé — coöperate!",
    "## Heading > with [markdown](./links.md) and `code spans`",
    "snake_case_names and CamelCaseNames and kebab-case-names",
    "a $5,000/year 50% discount... obviously!!",
    "supercalifragilisticexpialidocious antidisestablishmentarianism",
];

mkdirSync(OUT, { recursive: true });

// vocab.txt: id order from tokenizer.json's model.vocab map
const tokenizerJson = JSON.parse(
    readFileSync(join(env.localModelPath, MODEL, "tokenizer.json"), "utf8"));
const vocab = tokenizerJson.model.vocab;
const byId = Object.entries(vocab).sort((a, b) => a[1] - b[1]).map(([piece]) => piece);
writeFileSync(`${OUT}/vocab.txt`, byId.join("\n") + "\n");
console.log(`vocab.txt: ${byId.length} pieces`);

const tok = await AutoTokenizer.from_pretrained(MODEL);
const lines = [];
for (const text of PROBES) {
    if (text.includes("\n")) throw new Error("probes must be single-line");
    const ids = Array.from(tok(text).input_ids.data, Number);
    lines.push(text, ids.join(" "));
}
writeFileSync(`${OUT}/tokenisations.txt`, lines.join("\n") + "\n");
console.log(`tokenisations.txt: ${PROBES.length} probes`);
