// The extension's wasm build under Node (V8, the same engine as
// Chrome's):  node bench.mjs [transfers]
//
// The wasm imports two host functions and nothing else — no glue
// library — so this file is the whole host.
import { readFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';

const FIELDS = ['expand', 'transpose', 'check', 'hash', 'all', 'sent'];
/// One bot-held seat for one hand (packages/engine/tool/circuit_count.dart).
const GATES = 53726;

const m = Number(process.argv[2] ?? 1 << 20);
const wasm = readFileSync(new URL('./target/wasm32-unknown-unknown/release/ot_bench.wasm', import.meta.url));
const out = {};
const { instance } = await WebAssembly.instantiate(wasm, {
  env: { now: () => performance.now(), report: (id, v) => (out[FIELDS[id]] = v) },
});

instance.exports.bench(1 << 14, 1n); // warm
instance.exports.bench(m, 2n);

const ns = (ms) => (ms * 1e6) / m;
console.log(`${m} extended transfers, wasm under node ${process.versions.v8.split('.').slice(0, 2).join('.')}\n`);
for (const f of ['expand', 'transpose', 'check', 'hash', 'all']) {
  console.log(`  ${f.padEnd(11)} ${out[f].toFixed(1).padStart(8)} ms  ${ns(out[f]).toFixed(1).padStart(8)} ns each`);
}
const lean = out.expand + out.transpose + out.hash;
console.log(`  without the check,        ${ns(lean).toFixed(1).padStart(8)} ns each`);
console.log(`\n  on the wire ${out.sent} bytes  ${(out.sent / m).toFixed(1)} bytes each`);
console.log(`\nfor a seat's ${GATES} AND gates, at one transfer a gate:`);
console.log(
  `  ${((ns(out.all) * GATES) / 1e6).toFixed(0)} ms as measured, ` +
    `${((ns(lean) * GATES) / 1e6).toFixed(0)} ms without the check, ` +
    `${((out.sent / m) * GATES / 1024).toFixed(0)} KB on the wire`,
);
